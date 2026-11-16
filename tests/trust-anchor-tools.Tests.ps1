# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

$script:RepositoryRoot=Split-Path -Parent $PSScriptRoot
$script:ModulePath=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'
$script:Module=Import-Module $script:ModulePath -PassThru -Force

$script:TrustAnchorTestHostSource=@'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security.Cryptography;
using System.Security;
namespace SyuanTsai.AIInstructions.TrustAnchor.Tests {
    public static class ConPtyConsoleBinding {
        const uint GENERIC_READ=0x80000000,GENERIC_WRITE=0x40000000,FILE_SHARE_READ=1,FILE_SHARE_WRITE=2,OPEN_EXISTING=3;static IntPtr input=IntPtr.Zero;
        [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [System.Runtime.InteropServices.DllImport("kernel32.dll",SetLastError=true)] static extern bool SetStdHandle(int standardHandle,IntPtr handle);
        public static void BindInput(){input=CreateFileW("CONIN$",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,IntPtr.Zero,OPEN_EXISTING,0,IntPtr.Zero);if(input==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error(),"CreateFileW(CONIN$)");if(!SetStdHandle(-10,input))throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error(),"SetStdHandle(STD_INPUT_HANDLE)");}
    }
    public static class CryptoProbe {
        public static bool CanDecrypt(byte[] der, char[] password) {
            using (RSA rsa = RSA.Create()) { int read; rsa.ImportEncryptedPkcs8PrivateKey(password.AsSpan(), der, out read); return read == der.Length; }
        }
    }
    public sealed class SecureStringHost : PSHost {
        private readonly Guid instanceId=Guid.NewGuid();
        private readonly SecureStringHostUi ui;
        public SecureStringHost(SecureString[] responses,Action<int> beforeRead){ui=new SecureStringHostUi(responses,beforeRead);}
        public static bool IsDisposed(SecureString value){try{using(SecureString copy=value.Copy()){}return false;}catch(ObjectDisposedException){return true;}}
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
        private readonly Action<int> beforeRead;
        public int ReadCount { get; private set; }
        public SecureStringHostUi(SecureString[] values,Action<int> callback){responses=new Queue<SecureString>(values??Array.Empty<SecureString>());beforeRead=callback;}
        private SecureString NextSecureString(){ReadCount++;if(beforeRead!=null)beforeRead(ReadCount);if(responses.Count==0)throw new InvalidOperationException("No secure response remains.");return responses.Dequeue().Copy();}
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
$script:TrustAnchorConPtySource=@'
using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace SyuanTsai.AIInstructions.TrustAnchor.Tests {
    public sealed class ConPtyResult { public int ExitCode { get; set; } public string Output { get; set; } = ""; }
    public static class ConPtyLauncher {
        const uint EXTENDED_STARTUPINFO_PRESENT=0x00080000;
        const uint WAIT_OBJECT_0=0;
        const uint WAIT_TIMEOUT=258;
        static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE=(IntPtr)0x00020016;
        [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; public COORD(short x,short y){X=x;Y=y;} }
        [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO { public int cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
        [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
        [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,IntPtr attributes,uint size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern int CreatePseudoConsole(COORD size,IntPtr input,IntPtr output,uint flags,out IntPtr pseudoConsole);
        [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr pseudoConsole);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inheritHandles,uint creationFlags,IntPtr environment,string currentDirectory,ref STARTUPINFOEX startupInfo,out PROCESS_INFORMATION processInformation);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint exitCode);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
        static void Check(bool ok,string operation){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error(),operation);}
        static string Quote(string value){if(value.Length>0&&!value.Any(c=>char.IsWhiteSpace(c)||c=='\"'))return value;var b=new StringBuilder("\"");int slashes=0;foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='\"'){b.Append('\\',slashes*2+1);b.Append(c);slashes=0;continue;}b.Append('\\',slashes);slashes=0;b.Append(c);}b.Append('\\',slashes*2);b.Append('\"');return b.ToString();}
        public static ConPtyResult Run(string application,string[] arguments,string currentDirectory,uint timeoutMilliseconds){
            IntPtr inputRead=IntPtr.Zero,inputWrite=IntPtr.Zero,outputRead=IntPtr.Zero,outputWrite=IntPtr.Zero,pseudo=IntPtr.Zero,list=IntPtr.Zero;PROCESS_INFORMATION pi=default;FileStream outputStream=null;StreamReader reader=null;
            try{
                Check(CreatePipe(out inputRead,out inputWrite,IntPtr.Zero,0),"CreatePipe(input)");Check(CreatePipe(out outputRead,out outputWrite,IntPtr.Zero,0),"CreatePipe(output)");
                int hr=CreatePseudoConsole(new COORD(120,40),inputRead,outputWrite,0,out pseudo);if(hr!=0)Marshal.ThrowExceptionForHR(hr);
                IntPtr size=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);list=Marshal.AllocHGlobal(size);Check(InitializeProcThreadAttributeList(list,1,0,ref size),"InitializeProcThreadAttributeList");Check(UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,pseudo,(IntPtr)IntPtr.Size,IntPtr.Zero,IntPtr.Zero),"UpdateProcThreadAttribute");
                var startup=new STARTUPINFOEX();startup.StartupInfo.cb=Marshal.SizeOf<STARTUPINFOEX>();startup.StartupInfo.dwFlags=0;startup.lpAttributeList=list;
                var command=new StringBuilder(string.Join(" ",new[]{Quote(application)}.Concat((arguments??Array.Empty<string>()).Select(Quote))));
                Check(CreateProcessW(application,command,IntPtr.Zero,IntPtr.Zero,false,EXTENDED_STARTUPINFO_PRESENT,IntPtr.Zero,currentDirectory,ref startup,out pi),"CreateProcessW");Check(CloseHandle(inputRead),"CloseHandle(inputRead)");inputRead=IntPtr.Zero;Check(CloseHandle(outputWrite),"CloseHandle(outputWrite)");outputWrite=IntPtr.Zero;Check(CloseHandle(pi.hThread),"CloseHandle(thread)");pi.hThread=IntPtr.Zero;
                var safeOutput=new SafeFileHandle(outputRead,false);outputStream=new FileStream(safeOutput,FileAccess.Read,4096,true);reader=new StreamReader(outputStream,new UTF8Encoding(false,false),true,4096,true);var readTask=reader.ReadToEndAsync();
                uint wait=WaitForSingleObject(pi.hProcess,timeoutMilliseconds);if(wait==WAIT_TIMEOUT)throw new TimeoutException("ConPTY child timed out.");if(wait!=WAIT_OBJECT_0)throw new Win32Exception(Marshal.GetLastWin32Error(),"WaitForSingleObject");uint exitCode;Check(GetExitCodeProcess(pi.hProcess,out exitCode),"GetExitCodeProcess");ClosePseudoConsole(pseudo);pseudo=IntPtr.Zero;string output=readTask.GetAwaiter().GetResult();return new ConPtyResult{ExitCode=unchecked((int)exitCode),Output=output};
            }finally{
                if(reader!=null)reader.Dispose();if(outputStream!=null)outputStream.Dispose();if(pi.hThread!=IntPtr.Zero)CloseHandle(pi.hThread);if(pi.hProcess!=IntPtr.Zero)CloseHandle(pi.hProcess);if(list!=IntPtr.Zero){DeleteProcThreadAttributeList(list);Marshal.FreeHGlobal(list);}if(pseudo!=IntPtr.Zero)ClosePseudoConsole(pseudo);foreach(IntPtr handle in new[]{inputRead,inputWrite,outputRead,outputWrite})if(handle!=IntPtr.Zero)CloseHandle(handle);
            }
        }
    }
}
'@
if($null-eq('SyuanTsai.AIInstructions.TrustAnchor.Tests.CryptoProbe'-as[type])){
    Add-Type -TypeDefinition $script:TrustAnchorTestHostSource
}
if($IsWindows-and$null-eq('SyuanTsai.AIInstructions.TrustAnchor.Tests.ConPtyLauncher'-as[type])){
    Add-Type -TypeDefinition $script:TrustAnchorConPtySource
}

function Get-TestFailure {param([scriptblock]$Action)try{& $Action;throw 'Expected the action to fail.'}catch{return $_}}
function Write-TestPrivateKeyFixture {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    if($IsWindows){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$stream=$null
        try{
            $security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false)
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
            $stream=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$security)
            $readback=[IO.FileSystemAclExtensions]::GetAccessControl($stream);$owner=$readback.GetOwner([Security.Principal.SecurityIdentifier]);$rules=@($readback.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            if($owner.Value-cne$identity.User.Value-or-not$readback.AreAccessRulesProtected-or$rules.Count-ne1-or$rules[0].IsInherited-or$rules[0].AccessControlType-cne[Security.AccessControl.AccessControlType]::Allow-or$rules[0].IdentityReference.Value-cne$identity.User.Value){throw 'Private-key fixture DACL readback differs before write.'}
            $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)
        }finally{if($null-ne$stream){$stream.Dispose()};$identity.Dispose()}
        return
    }
    $options=[IO.FileStreamOptions]::new();$options.Mode=[IO.FileMode]::CreateNew;$options.Access=[IO.FileAccess]::Write;$options.Share=[IO.FileShare]::None;$options.UnixCreateMode=[IO.UnixFileMode]::UserRead-bor[IO.UnixFileMode]::UserWrite
    $stream=[IO.FileStream]::new($Path,$options);try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function ConvertTo-TestCanonicalXmlBytes {
    param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    $parameters=$Rsa.ExportParameters($false);$text='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent></RSAKeyValue>'+"`n"
    return ,([Text.UTF8Encoding]::new($false).GetBytes($text))
}
function New-TestSecretSpec {param([int]$Seed=1729,[int]$Length=32)[pscustomobject]@{Seed=$Seed;Length=$Length}}
function New-TestMutantTrustAnchorCliRoot {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$ModuleSource,[string]$WindowsInstallerMutationSource,[string]$WindowsNativeSource)
    $root=Join-Path $TestDrive "mutant-$Name";[void][IO.Directory]::CreateDirectory($root);Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts') -Destination $root -Recurse -Force;$modulePath=Join-Path $root 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1';[IO.File]::WriteAllText($modulePath,$ModuleSource,[Text.UTF8Encoding]::new($false))
    if(-not[string]::IsNullOrEmpty($WindowsInstallerMutationSource)){
        $normalized=$WindowsInstallerMutationSource.Replace("`r`n","`n").Replace("`r","`n");$nativePath=Join-Path $root 'scripts/platform/WindowsInstallerMutation.cs';[IO.File]::WriteAllText($nativePath,$normalized,[Text.UTF8Encoding]::new($false));$hash=Get-TestSha256Text $normalized;$manifestPath=Join-Path $root 'scripts/platform-runtime.psd1';$manifest=[IO.File]::ReadAllText($manifestPath);$manifest=$manifest.Replace('b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218',$hash);[IO.File]::WriteAllText($manifestPath,$manifest,[Text.UTF8Encoding]::new($false))
    }
    if(-not[string]::IsNullOrEmpty($WindowsNativeSource)){$normalized=$WindowsNativeSource.Replace("`r`n","`n").Replace("`r","`n");$nativePath=Join-Path $root 'scripts/platform/WindowsNative.cs';[IO.File]::WriteAllText($nativePath,$normalized,[Text.UTF8Encoding]::new($false));$hash=Get-TestSha256Text $normalized;$manifestPath=Join-Path $root 'scripts/platform-runtime.psd1';$manifest=[IO.File]::ReadAllText($manifestPath);$manifest=$manifest.Replace('6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433',$hash);[IO.File]::WriteAllText($manifestPath,$manifest,[Text.UTF8Encoding]::new($false))}
    return (Join-Path $root 'scripts/trust-anchor')
}
function Remove-TestAstExtents {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][object[]]$Nodes)
    $mutated=$Source;foreach($node in @($Nodes|Sort-Object{$_.Extent.StartOffset}-Descending)){$mutated=Set-TestSourceSpan $mutated $node.Extent.StartOffset ($node.Extent.EndOffset-$node.Extent.StartOffset) '$null'};return $mutated
}
function Get-TestDirectoryMoveAdversaryScript {
    return {
        param($signal,$witness,$parent,$displaced)
        while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)}
        try{
            if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
                Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class TrustAnchorMoveProbeFix10{[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]public static extern bool MoveFileExW(string existing,string replacement,uint flags);}'
                if(-not[TrustAnchorMoveProbeFix10]::MoveFileExW($parent,$displaced,0)){$nativeError=[Runtime.InteropServices.Marshal]::GetLastWin32Error();throw [ComponentModel.Win32Exception]::new($nativeError)}
            }else{[IO.Directory]::Move($parent,$displaced)}
            [void][IO.Directory]::CreateDirectory($parent);[void][IO.Directory]::CreateDirectory([IO.Path]::Combine($parent,'.git'));[pscustomobject]@{Succeeded=$true;OriginalExists=[IO.Directory]::Exists($displaced);ReplacementGit=[IO.Directory]::Exists([IO.Path]::Combine($parent,'.git'))}|Export-Clixml -LiteralPath $witness
        }catch{$nativeError=if($_.Exception-is[ComponentModel.Win32Exception]){$_.Exception.NativeErrorCode}else{$null};[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message;HResult=[int]$_.Exception.HResult;Win32Error=$nativeError}|Export-Clixml -LiteralPath $witness}
    }
}
function Get-TestSecretText {
    param([Parameter(Mandatory)][int]$Seed,[Parameter(Mandatory)][int]$Length)
    $characters=[char[]]::new($Length);for($index=0;$index-lt$Length;$index++){$characters[$index]=[char]([int][char]'a'+(($Seed+$index*7)%26))};return -join$characters
}
function Get-TestCliDriverSource {
    return @'
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Worker)
$config=Import-Clixml -LiteralPath $ConfigPath
if([bool]$config.UseConPty-and-not$Worker){
    Add-Type -TypeDefinition ([IO.File]::ReadAllText([string]$config.HostSourcePath));[SyuanTsai.AIInstructions.TrustAnchor.Tests.ConPtyConsoleBinding]::BindInput()
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$info.UseShellExecute=$false;foreach($value in @('-NoProfile','-File',$PSCommandPath,'-ConfigPath',$ConfigPath,'-Worker')){$info.ArgumentList.Add($value)};$workerProcess=[Diagnostics.Process]::Start($info);$workerProcess.WaitForExit();$workerExit=$workerProcess.ExitCode;$workerProcess.Dispose();exit $workerExit
}
foreach($name in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')){[Environment]::SetEnvironmentVariable($name,$null)}
if(-not[string]::IsNullOrWhiteSpace([string]$config.CiMarker)){[Environment]::SetEnvironmentVariable([string]$config.CiMarker,'1')}
$state=$null;$powershell=$null;$runspace=$null;$testHost=$null;$output=@();$errors=@();$invokeFailure=$null;$transcriptStarted=$false;$responses=[Collections.Generic.List[Security.SecureString]]::new();$responseCharacters=[Collections.Generic.List[char[]]]::new();$driverExitCode=0
function New-DriverSecretCharacters {param([int]$Seed,[int]$Length)$value=[char[]]::new($Length);for($index=0;$index-lt$Length;$index++){$value[$index]=[char]([int][char]'a'+(($Seed+$index*7)%26))};return ,$value}
function Test-DriverContainsCharacters {param([AllowEmptyString()][string]$Value,[char[]]$Characters)if($Characters.Length-eq0-or$Value.Length-lt$Characters.Length){return $false};for($offset=0;$offset-le$Value.Length-$Characters.Length;$offset++){$same=$true;for($index=0;$index-lt$Characters.Length;$index++){if($Value[$offset+$index]-cne$Characters[$index]){$same=$false;break}};if($same){return $true}};return $false}
try{
    Add-Type -TypeDefinition ([IO.File]::ReadAllText([string]$config.HostSourcePath))
    $state=[pscustomobject]@{InputRedirected=[Console]::IsInputRedirected;UserInteractive=[Environment]::UserInteractive}
    foreach($spec in @($config.ResponseSpecs)){$characters=New-DriverSecretCharacters ([int]$spec.Seed) ([int]$spec.Length);$responseCharacters.Add($characters);$secure=[Security.SecureString]::new();foreach($character in $characters){$secure.AppendChar($character)};$secure.MakeReadOnly();$responses.Add($secure)}
    $beforeRead=[Action[int]]{param($readCount)foreach($barrier in @($config.BarrierSpecs)){if([int]$barrier.ReadCount-ne$readCount){continue};[IO.File]::WriteAllText([string]$barrier.SignalPath,[string]$readCount,[Text.UTF8Encoding]::new($false));$deadline=[DateTime]::UtcNow.AddMilliseconds([int]$barrier.TimeoutMilliseconds);while(-not[IO.File]::Exists([string]$barrier.WitnessPath)){if([DateTime]::UtcNow-ge$deadline){throw "Timed out waiting for adversary barrier witness at read ${readCount}."};[Threading.Thread]::Sleep(10)}}}
    $testHost=[SyuanTsai.AIInstructions.TrustAnchor.Tests.SecureStringHost]::new([Security.SecureString[]]$responses.ToArray(),$beforeRead)
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($testHost);$powershell=[Management.Automation.PowerShell]::Create();$runspace.Open();$powershell.Runspace=$runspace
    if([bool]$config.PreloadTamper){
        $runspace.SessionStateProxy.SetVariable('TrustAnchorPreloadModulePath',[string]$config.ModulePath);[void]$powershell.AddScript('$module=Microsoft.PowerShell.Core\Import-Module $TrustAnchorPreloadModulePath -PassThru -Force -ErrorAction Stop;& $module {function script:Assert-TrustAnchorInteractiveHost {};function script:Read-TrustAnchorPassword {[Security.SecureString]::new()};$script:TrustAnchorInteractiveOverride=''tampered''}')
        [void]$powershell.Invoke();if($powershell.HadErrors){throw $powershell.Streams.Error[0]};$powershell.Commands.Clear();$powershell.Streams.Error.Clear()
    }
    if([bool]$config.PreloadPathTamper){
        $runspace.SessionStateProxy.SetVariable('TrustAnchorFakeModulePath',[string]$config.FakeModulePath);$runspace.SessionStateProxy.SetVariable('TrustAnchorModuleDirectory',[IO.Path]::GetDirectoryName([string]$config.ModulePath));[void]$powershell.AddScript('function global:Join-Path { param($Path,$ChildPath,[string[]]$AdditionalChildPath) if([string]$ChildPath -ceq ''scripts/platform-runtime.psd1''){return $TrustAnchorFakeModulePath};Microsoft.PowerShell.Management\Join-Path @PSBoundParameters };function global:Split-Path { param($Path,[switch]$Parent,[switch]$Leaf,[switch]$Qualifier,[switch]$NoQualifier,[switch]$IsAbsolute,[switch]$Resolve) if([string]$Path -ceq $TrustAnchorModuleDirectory){return [IO.Path]::GetDirectoryName($TrustAnchorFakeModulePath)};Microsoft.PowerShell.Management\Split-Path @PSBoundParameters };function global:Import-Module { param($Name,[switch]$Global,[string]$Prefix,[switch]$PassThru,[switch]$Force,$Scope,$ErrorAction) if([string]$Name -ceq $TrustAnchorFakeModulePath){return Microsoft.PowerShell.Core\Import-Module -Name $TrustAnchorFakeModulePath -Force -PassThru};$forward=@{};foreach($entry in $PSBoundParameters.GetEnumerator()){if([string]$entry.Key -cne ''Name''){$forward[$entry.Key]=$entry.Value}};Microsoft.PowerShell.Core\Import-Module -Name $Name @forward };function global:Read-Host { [Security.SecureString]::new() }')
        [void]$powershell.Invoke();if($powershell.HadErrors){throw $powershell.Streams.Error[0]};$powershell.Commands.Clear();$powershell.Streams.Error.Clear()
    }
    [void]$powershell.AddCommand('Start-Transcript').AddParameter('LiteralPath',[string]$config.TranscriptPath).AddParameter('Force');[void]$powershell.Invoke();if($powershell.HadErrors){throw $powershell.Streams.Error[0]};$transcriptStarted=$true;$powershell.Commands.Clear();$powershell.Streams.Error.Clear()
    [void]$powershell.AddCommand([string]$config.Path);foreach($name in $config.Parameters.Keys){[void]$powershell.AddParameter([string]$name,$config.Parameters[$name])}
    try{$output=@($powershell.Invoke())}catch{$invokeFailure=$_};$errors=@($powershell.Streams.Error);if($null-ne$invokeFailure-and$errors.Count-eq0){$errors=@($invokeFailure)};$hadErrors=$powershell.HadErrors-or$null-ne$invokeFailure
    $errorIds=@($errors|ForEach-Object{if($null-ne$_.Exception.InnerException-and$null-ne$_.Exception.InnerException.ErrorRecord){[string]$_.Exception.InnerException.ErrorRecord.FullyQualifiedErrorId}elseif($null-ne$_.Exception.ErrorRecord){[string]$_.Exception.ErrorRecord.FullyQualifiedErrorId}else{[string]$_.FullyQualifiedErrorId}})
    $errorMessages=@($errors|ForEach-Object{if($null-ne$_.Exception.InnerException-and$null-ne$_.Exception.InnerException.ErrorRecord){[string]$_.Exception.InnerException.ErrorRecord.Exception.Message}elseif($null-ne$_.Exception.ErrorRecord){[string]$_.Exception.ErrorRecord.Exception.Message}else{[string]$_.Exception.Message}});$environmentContainsSentinel=$false
    foreach($value in [Environment]::GetEnvironmentVariables().Values){foreach($characters in $responseCharacters){if(Test-DriverContainsCharacters ([string]$value) $characters){$environmentContainsSentinel=$true}}}
    [pscustomobject]@{Output=$output;ErrorIds=$errorIds;ErrorMessages=$errorMessages;ReadCount=$testHost.ReadCount;HadErrors=$hadErrors;InteractiveState=$state;EnvironmentContainsSentinel=$environmentContainsSentinel;PathTamperWitnessExists=if([string]::IsNullOrWhiteSpace([string]$config.PathTamperWitnessPath)){$false}else{[IO.File]::Exists([string]$config.PathTamperWitnessPath)}}|Export-Clixml -LiteralPath ([string]$config.ResultPath) -Depth 8
}catch{
    $driverExitCode=1;[pscustomobject]@{Output=@();ErrorIds=@([string]$_.FullyQualifiedErrorId);ErrorMessages=@([string]$_.Exception.Message);ReadCount=if($null-eq$testHost){0}else{$testHost.ReadCount};HadErrors=$true;InteractiveState=$state;DriverFailure=$true}|Export-Clixml -LiteralPath ([string]$config.ResultPath) -Depth 8
}finally{
    if($transcriptStarted-and$null-ne$powershell){$powershell.Commands.Clear();$powershell.Streams.Error.Clear();[void]$powershell.AddCommand('Stop-Transcript');[void]$powershell.Invoke()}
    if($null-ne$powershell){$powershell.Dispose()};if($null-ne$runspace){$runspace.Dispose()};foreach($response in $responses){$response.Dispose()};foreach($characters in $responseCharacters){[Array]::Clear($characters,0,$characters.Length)}
    $disposed=@($responses|ForEach-Object{[SyuanTsai.AIInstructions.TrustAnchor.Tests.SecureStringHost]::IsDisposed($_)});$zeroed=@($responseCharacters|ForEach-Object{(@($_|Where-Object{$_-ne[char]0}).Count-eq0)})
    if([IO.File]::Exists([string]$config.ResultPath)){$cleanupResult=Import-Clixml -LiteralPath ([string]$config.ResultPath);$cleanupResult|Add-Member NoteProperty ResponseCleanupDisposed $disposed;$cleanupResult|Add-Member NoteProperty ResponseCleanupZeroed $zeroed;$cleanupResult|Export-Clixml -LiteralPath ([string]$config.ResultPath) -Depth 8}
}
if($driverExitCode-ne0){exit $driverExitCode}
'@
}
function Invoke-TestTrustAnchorCli {
    param(
        [Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Parameters,[object[]]$ResponseSpecs=@(),
        [string]$CiMarker,[switch]$PreloadTamper,[switch]$PreloadPathTamper,[object[]]$BarrierSpecs=@(),[string]$DriverSource
    )
    $id=[Guid]::NewGuid().ToString('N');$driver=Join-Path $TestDrive "trust-anchor-cli-driver-$id.ps1";$configPath=Join-Path $TestDrive "trust-anchor-cli-config-$id.clixml";$hostSource=Join-Path $TestDrive "trust-anchor-host-$id.cs";$resultPath=Join-Path $TestDrive "trust-anchor-cli-result-$id.clixml";$transcriptPath=Join-Path $TestDrive "trust-anchor-cli-transcript-$id.txt";$stdoutPath=Join-Path $TestDrive "trust-anchor-cli-stdout-$id.txt";$stderrPath=Join-Path $TestDrive "trust-anchor-cli-stderr-$id.txt";$fakeModulePath=Join-Path $TestDrive "trust-anchor-fake-$id.psm1";$pathTamperWitnessPath=Join-Path $TestDrive "trust-anchor-fake-$id.witness"
    $artifacts=@($driver,$configPath,$hostSource,$resultPath,$transcriptPath,$stdoutPath,$stderrPath,$fakeModulePath,$pathTamperWitnessPath);$process=$null;$result=$null
    try{
        if([string]::IsNullOrEmpty($DriverSource)){$DriverSource=Get-TestCliDriverSource};[IO.File]::WriteAllText($driver,$DriverSource,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($hostSource,$script:TrustAnchorTestHostSource,[Text.UTF8Encoding]::new($false));if($PreloadPathTamper){$escaped=$pathTamperWitnessPath.Replace("'","''");[IO.File]::WriteAllText($fakeModulePath,"[IO.File]::WriteAllText('$escaped','loaded');function Read-Host {[Security.SecureString]::new()};function Assert-TrustAnchorInteractiveHost {};function Invoke-GetTrustAnchorFingerprintAction {}",[Text.UTF8Encoding]::new($false))}
        [pscustomobject]@{Path=$Path;Parameters=$Parameters;ResponseSpecs=$ResponseSpecs;ModulePath=$script:ModulePath;PreloadTamper=[bool]$PreloadTamper;PreloadPathTamper=[bool]$PreloadPathTamper;FakeModulePath=$fakeModulePath;PathTamperWitnessPath=$pathTamperWitnessPath;BarrierSpecs=$BarrierSpecs;CiMarker=$CiMarker;UseConPty=[bool]$IsWindows;HostSourcePath=$hostSource;ResultPath=$resultPath;TranscriptPath=$transcriptPath}|Export-Clixml -LiteralPath $configPath -Depth 8
        $pwshCommand=@(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0];$pwsh=if($IsWindows){[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName}else{[string]$pwshCommand.Source}
        if($IsWindows){$conpty=[SyuanTsai.AIInstructions.TrustAnchor.Tests.ConPtyLauncher]::Run($pwsh,@('-NoProfile','-File',$driver,'-ConfigPath',$configPath),$script:RepositoryRoot,180000);[IO.File]::WriteAllText($stdoutPath,$conpty.Output);[IO.File]::WriteAllText($stderrPath,'');$exitCode=$conpty.ExitCode}
        else{
            $scriptCommand=@(Get-Command script -CommandType Application -ErrorAction Stop)[0];$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[string]$scriptCommand.Source;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            if($IsLinux){$quote={param($value)$single=[string][char]39;$double=[string][char]34;return $single+([string]$value).Replace($single,($single+$double+$single+$double+$single))+$single};$command=(& $quote $pwsh)+' -NoProfile -File '+(& $quote $driver)+' -ConfigPath '+(& $quote $configPath);$info.ArgumentList.Add('-qec');$info.ArgumentList.Add($command);$info.ArgumentList.Add('/dev/null')}
            else{$info.ArgumentList.Add('-q');$info.ArgumentList.Add('/dev/null');foreach($value in @($pwsh,'-NoProfile','-File',$driver,'-ConfigPath',$configPath)){$info.ArgumentList.Add($value)}}
            $process=[Diagnostics.Process]::Start($info);$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$exitCode=$process.ExitCode;[IO.File]::WriteAllText($stdoutPath,$stdoutTask.GetAwaiter().GetResult());[IO.File]::WriteAllText($stderrPath,$stderrTask.GetAwaiter().GetResult())
        }
        if($exitCode-ne0-or-not(Test-Path -LiteralPath $resultPath)){throw "The interactive console driver failed with exit code ${exitCode}: $([IO.File]::ReadAllText($stderrPath))"}
        $result=Import-Clixml -LiteralPath $resultPath;$compatErrors=@();for($index=0;$index-lt@($result.ErrorIds).Count;$index++){$errorId=[string]$result.ErrorIds[$index];$message=[string]$result.ErrorMessages[$index];$compatErrors+=[pscustomobject]@{FullyQualifiedErrorId=$errorId;Exception=[pscustomobject]@{Message=$message;InnerException=[pscustomobject]@{ErrorRecord=[pscustomobject]@{FullyQualifiedErrorId=$errorId}}}}};$result|Add-Member NoteProperty Errors $compatErrors;$result|Add-Member NoteProperty Stdout ([IO.File]::ReadAllText($stdoutPath));$result|Add-Member NoteProperty Stderr ([IO.File]::ReadAllText($stderrPath));$result|Add-Member NoteProperty Transcript $(if(Test-Path -LiteralPath $transcriptPath){[IO.File]::ReadAllText($transcriptPath)}else{''});$result|Add-Member NoteProperty SurfacePaths $artifacts;$result|Add-Member NoteProperty ArtifactContents @($artifacts|ForEach-Object{if(Test-Path -LiteralPath $_){[Text.UTF8Encoding]::new($false,$false).GetString([IO.File]::ReadAllBytes($_))}else{''}});$result|Add-Member NoteProperty ResponseSentinels @($ResponseSpecs|ForEach-Object{Get-TestSecretText ([int]$_.Seed) ([int]$_.Length)})
    }finally{if($null-ne$process){$process.Dispose()};foreach($artifact in $artifacts){Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue}}
    return $result
}
function Test-TestSentinelAbsentFromCliSurfaces {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Sentinel,[string[]]$OutputPaths=@())
    if($Result.EnvironmentContainsSentinel){return $false};$surfaces=@([string]$Result.Stdout,[string]$Result.Stderr,[string]$Result.Transcript,($Result.Output|Out-String),($Result.ErrorIds|Out-String),($Result.ErrorMessages|Out-String))+@($Result.ArtifactContents)
    foreach($path in @($OutputPaths|Select-Object -Unique)){if(Test-Path -LiteralPath $path){$surfaces+=[Text.UTF8Encoding]::new($false,$false).GetString([IO.File]::ReadAllBytes($path))}}
    foreach($surface in $surfaces){if(([string]$surface).Contains($Sentinel,[StringComparison]::Ordinal)){return $false}};foreach($path in @($Result.SurfacePaths)){if(Test-Path -LiteralPath $path){return $false}};return $true
}
function Assert-TestSentinelAbsentFromCliSurfaces {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Sentinel,[string[]]$OutputPaths=@())
    (Test-TestSentinelAbsentFromCliSurfaces $Result $Sentinel $OutputPaths)|Should Be $true
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
function Get-TestCSharpTokenContract {
    param([Parameter(Mandatory)][string]$Source)
    $tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($Source.Replace("`r`n","`n").Replace("`r","`n"));if(@($tree.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){return $null}
    $records=@($tree.GetRoot().DescendantTokens()|ForEach-Object{$kind=[Enum]::GetName([Microsoft.CodeAnalysis.CSharp.SyntaxKind],$_.RawKind);$value=$_.Text;"$kind|$($value.Length):$value"})
    return [pscustomobject]@{TokenCount=$records.Count;Sha256=(Get-TestSha256Text ($records-join"`n"))}
}
function Get-TrustAnchorProtectedContracts {
    return @{
        'scripts/trust-anchor/TrustAnchorPrivateKey.psm1'=@{TokenCount=3901;Sha256='cf968d27573fc536e48dd14eded62f1ca5974217ad3b5d95362dbf28a6510917'}
        'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1'=@{TokenCount=110;Sha256='9957a095dbfbf8640cdf5a8611219e55775cfdcf3a46c4789a23f360f49f76f5'}
        'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1'=@{TokenCount=86;Sha256='1f42500679c905fbb8662df71f08087535160891b3bcc1bfb39e88f50b539a9e'}
        'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'=@{TokenCount=117;Sha256='7690182cf612e77daa3f106ae16dc46540e131e2849645591436ae342b6fe27f'}
        'scripts/platform/WindowsInstallerMutation.cs'=@{TokenCount=3104;Sha256='2b997cd7670a5623aa228230df8c80fccb791f63f00c948d0af865e97896fb18';Language='CSharp'}
        'scripts/platform/WindowsNative.cs'=@{TokenCount=9135;Sha256='9bf94dc493535419b1527ba5a8f6e8c19850de84c7f752d86a20c7f70d1e0235';Language='CSharp'}
    }
}
function Test-TrustAnchorProtectedContract {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Source)
    $expected=(Get-TrustAnchorProtectedContracts)[$RelativePath];if($null-eq$expected){return $false}
    $actual=if($expected.Language-ceq'CSharp'){Get-TestCSharpTokenContract $Source}else{Get-TrustAnchorProtectedTokenContract $Source}
    return $null-ne$actual-and$actual.TokenCount-eq$expected.TokenCount-and$actual.Sha256-ceq$expected.Sha256
}
function Test-TrustAnchorModulePreGuardAst {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ModuleSource,[ref]$tokens,[ref]$errors);if(@($errors).Count-ne0){return $false}
    $topLevel=@($ast.FindAll({param($node)if($node-isnot[Management.Automation.Language.CommandAst]){return $false};$cursor=$node.Parent;while($null-ne$cursor){if($cursor-is[Management.Automation.Language.FunctionDefinitionAst]){return $false};$cursor=$cursor.Parent};return $true},$true)|Sort-Object{$_.Extent.StartOffset}|ForEach-Object{"$($_.GetCommandName())|$(@($_.CommandElements|Where-Object{$_-is[Management.Automation.Language.CommandParameterAst]}|ForEach-Object{$_.ParameterName})-join',')"})
    $expectedTopLevel=@('Microsoft.PowerShell.Core\Set-StrictMode|Version','Microsoft.PowerShell.Core\Import-Module|Scope,ErrorAction','Microsoft.PowerShell.Utility\Add-Type|TypeDefinition','Microsoft.PowerShell.Core\Export-ModuleMember|Function');if(($topLevel-join"`n")-cne($expectedTopLevel-join"`n")){return $false}
    $assignment=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left-is[Management.Automation.Language.VariableExpressionAst]-and$_.Left.VariablePath.UserPath-ceq'script:PlatformRuntimePath'});if($assignment.Count-ne1-or(Get-CompactAstText $assignment[0].Right)-cne"[IO.Path]::GetFullPath([IO.Path]::Combine(`$PSScriptRoot,'..','platform-runtime.psd1'))"){return $false}
    $passwordFunction=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Read-TrustAnchorPassword'},$true));if($passwordFunction.Count-ne1){return $false};$passwordCommands=@($passwordFunction[0].FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]},$true)|Sort-Object{$_.Extent.StartOffset}|ForEach-Object{"$($_.GetCommandName())|$(@($_.CommandElements|Where-Object{$_-is[Management.Automation.Language.CommandParameterAst]}|ForEach-Object{$_.ParameterName})-join',')"});$expectedPassword=@('Microsoft.PowerShell.Utility\Read-Host|AsSecureString','New-TrustAnchorError|','Microsoft.PowerShell.Utility\Read-Host|AsSecureString','New-TrustAnchorError|','Use-TrustAnchorPassword|','Use-TrustAnchorPassword|','New-TrustAnchorError|');if(($passwordCommands-join"`n")-cne($expectedPassword-join"`n")){return $false}
    return $true
}
function Test-TrustAnchorWindowsDirectoryLeaseSemantics {
    param([Parameter(Mandatory)][string]$InstallerSource,[Parameter(Mandatory)][string]$NativeSource)
    $analysis=Get-TrustAnchorCSharpAnalysis $InstallerSource;if($null-eq$analysis){return $false};$methods=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'OpenValidatedDirectory'});if($methods.Count-ne1){return $false};$calls=@($methods[0].DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'CreateFile'});if($calls.Count-ne1-or$calls[0].ArgumentList.Arguments.Count-ne7-or($calls[0].ArgumentList.Arguments[2].Expression.ToString()-replace'\s','')-cne'FileShareRead|FileShareWrite'){return $false}
    $nativeTree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($NativeSource);if(@($nativeTree.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){return $false};$wrap=@($nativeTree.GetRoot().DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'WrapDirectory'});if($wrap.Count-ne1){return $false};$open=@($wrap[0].DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'Open'});return $open.Count-eq1-and$open[0].ArgumentList.Arguments.Count-eq4-and$open[0].ArgumentList.Arguments[2].Expression.ToString()-ceq'3'
}
function Test-TrustAnchorRollbackSemantics {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $csharp=Get-TrustAnchorEmbeddedCSharpSource $ModuleSource;$analysis=Get-TrustAnchorCSharpAnalysis $csharp;if($null-eq$analysis){return $false};$class=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'ClassDeclarationSyntax'-and$_.Identifier.ValueText-ceq'UnixRollbackLease'});if($class.Count-ne1){return $false}
    $sameFile=@($class[0].DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'SameFile'}|Sort-Object SpanStart|ForEach-Object{($_.ToString()-replace'\s','')});$expected=@('SameFile(before,device,inode)','SameFile(Stat(lease.directory,lease.TombstoneName),device,inode)','SameFile(UnixMetadataInspector.Inspect(lease.file),device,inode)','SameFile(Stat(directory,TombstoneName),device,inode)','SameFile(UnixMetadataInspector.Inspect(file),device,inode)');if(($sameFile-join"`n")-cne($expected-join"`n")){return $false}
    $sameFileMethod=@($class[0].Members|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'SameFile'});if($sameFileMethod.Count-ne1-or($sameFileMethod[0].ToString()-replace'\s','')-cnotmatch'LinkCount!=1'){return $false}
    $complete=@($class[0].Members|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'Complete'});if($complete.Count-ne1){return $false};$completeCalls=@($complete[0].DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'}|Sort-Object SpanStart);$unlink=@($completeCalls|Where-Object{$_.Expression.ToString()-cin@('unlinkatDarwin','unlinkatLinux')});$revalidations=@($completeCalls|Where-Object{$_.Expression.ToString()-ceq'SameFile'});return $unlink.Count-eq4-and$revalidations.Count-eq2-and$revalidations[-1].SpanStart-lt$unlink[0].SpanStart
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
            }elseif($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation-and$item.TargetMethod.ContainingType.ToString()-ceq'SyuanTsai.AIInstructions.TrustAnchor.SecretBridge'-and$item.TargetMethod.Name-ceq'Zero'){
                $records.Add("CSharp|$($method.Identifier.ValueText)|Zero|$($item.Arguments[0].Value.Syntax.ToString())|$(Get-TestCleanupContext $item.Syntax)")
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
CSharp|ImportEncryptedPem|Zero|pem|finally
PowerShell|Use-TrustAnchorPassword|ZeroFreeGlobalAllocUnicode|$buffer|finally
PowerShell|Use-TrustAnchorPassword|ZeroCharacters|$characters|finally
PowerShell|Use-TrustAnchorPassword|FreePin|$pin|finally
PowerShell|Read-TrustAnchorInputBytes|ZeroMemory|$bytes|finally
PowerShell|Read-TrustAnchorPrivateKeyLease|ZeroMemory|$bytes|finally
PowerShell|Get-TrustAnchorFingerprint|ZeroMemory|$spki|finally
PowerShell|Invoke-NewTrustAnchorKeyPairAction|ZeroMemory|$publicBytes|finally
PowerShell|Invoke-NewTrustAnchorKeyPairAction|ZeroMemory|$privateBytes|finally
PowerShell|Invoke-ConvertToTrustAnchorPublicKeyXmlAction|ZeroMemory|$inputBytes|finally
PowerShell|Invoke-ConvertToTrustAnchorPublicKeyXmlAction|ZeroMemory|$bytes|finally
PowerShell|Invoke-GetTrustAnchorFingerprintAction|ZeroMemory|$inputBytes|finally
'@
    return ($actual-join"`n")-ceq$expected.Trim()
}
function Get-TestDriverCleanupRecords {
    param([Parameter(Mandatory)][string]$DriverSource)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($DriverSource,[ref]$tokens,[ref]$errors);if(@($errors).Count-ne0){return $null};$records=[Collections.Generic.List[string]]::new()
    foreach($member in @($ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)|Sort-Object{$_.Extent.StartOffset})){
        $api=$null;$target=$null
        if(-not$member.Static-and$member.Member.Value-ceq'Dispose'-and$member.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$member.Expression.VariablePath.UserPath-ceq'response'){$api='Dispose';$target='$response'}
        elseif($member.Static-and$member.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$member.Expression.TypeName.FullName-ceq'Array'-and$member.Member.Value-ceq'Clear'){$api='Clear';$target=($member.Arguments|ForEach-Object{$_.Extent.Text})-join','}
        if($null-eq$api){continue};$loop=$member.Parent;while($null-ne$loop-and$loop-isnot[Management.Automation.Language.ForEachStatementAst]){$loop=$loop.Parent};$collection=if($null-eq$loop){'<none>'}else{$loop.Condition.Extent.Text};$records.Add("$api|$target|$collection|$(Get-TestCleanupContext $member)")
    }
    return ,$records.ToArray()
}
function Test-TestDriverCleanupContract {
    param([Parameter(Mandatory)][string]$DriverSource)
    $actual=Get-TestDriverCleanupRecords $DriverSource;if($null-eq$actual){return $false};return ($actual-join"`n")-ceq@'
Dispose|$response|$responses|finally
Clear|$characters,0,$characters.Length|$responseCharacters|finally
'@.Trim()
}
function Get-TestSecretCleanupInventory {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    $entries=[Collections.Generic.List[object]]::new()
    foreach($member in @($Ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)|Sort-Object{$_.Extent.StartOffset})){
        $api=$null;$target=$null
        if($member.Static-and$member.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$member.Expression.TypeName.FullName-cin@('Security.Cryptography.CryptographicOperations','System.Security.Cryptography.CryptographicOperations')-and$member.Member.Value-ceq'ZeroMemory'){$api='ZeroMemory';$target=$member.Arguments[0].Extent.Text}
        elseif($member.Static-and$member.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$member.Expression.TypeName.FullName-ceq'SyuanTsai.AIInstructions.TrustAnchor.SecretBridge'-and$member.Member.Value-ceq'Zero'){$api='ZeroCharacters';$target=$member.Arguments[0].Extent.Text}
        elseif($member.Static-and$member.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$member.Expression.TypeName.FullName-cin@('Array','System.Array')-and$member.Member.Value-ceq'Clear'){$api='ArrayClear';$target=($member.Arguments|ForEach-Object{$_.Extent.Text})-join','}
        elseif(-not$member.Static-and$member.Member.Value-ceq'Dispose'){$api='Dispose';$target=$member.Expression.Extent.Text}
        if($null-eq$api){continue};$record="$api|$(Get-TestAncestorScopeName $member)|$target|$(Get-TestCleanupContext $member)";$entries.Add([pscustomobject]@{Record=$record;Node=$member;Api=$api})
    }
    $records=@($entries|ForEach-Object{$_.Record});return [pscustomobject]@{Entries=$entries.ToArray();Records=$records;Count=$records.Count;Sha256=(Get-TestSha256Text ($records-join"`n"))}
}
function Test-TestSecretCleanupContract {
    param([Parameter(Mandatory)]$Inventory)
    return $null-ne$Inventory-and$Inventory.Count-eq57-and$Inventory.Sha256-ceq'9eee522aa9b7d6efe2bf6d8f7eec76f09119e99a1b047c8fd6f2e40bc86546cf'
}
function Test-TrustAnchorFilePrimitiveSemantics {
    param([Parameter(Mandatory)][string]$ModuleSource)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ModuleSource,[ref]$tokens,[ref]$errors);if(@($errors).Count-ne0){return $false}
    $functions=@{};foreach($name in @('New-TrustAnchorKeyFile','Get-TrustAnchorMetadataEvidence','Assert-TrustAnchorPrivatePermissions')){$matches=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true));if($matches.Count-ne1){return $false};$functions[$name]=$matches[0]}
    $new=$functions['New-TrustAnchorKeyFile'];$try=@($new.Body.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]});if($try.Count-ne1){return $false};$statements=@($try[0].Body.Statements);$expectedTypes=@('TryStatementAst','IfStatementAst','AssignmentStatementAst','AssignmentStatementAst','IfStatementAst','PipelineAst','PipelineAst','IfStatementAst','TryStatementAst','ReturnStatementAst');if((($statements|ForEach-Object{$_.GetType().Name})-join'|')-cne($expectedTypes-join'|')){return $false}
    $writes=@($new.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and-not$node.Static-and$node.Member.Value-ceq'WriteNewBytes'},$true));if($writes.Count-ne1-or$writes[0].Expression-isnot[Management.Automation.Language.VariableExpressionAst]-or$writes[0].Expression.VariablePath.UserPath-cne'file'-or$writes[0].Arguments.Count-ne1-or$writes[0].Arguments[0]-isnot[Management.Automation.Language.VariableExpressionAst]-or$writes[0].Arguments[0].VariablePath.UserPath-cne'Bytes'-or$statements[5].Extent.StartOffset-ne$writes[0].Parent.Extent.StartOffset){return $false}
    $permissionCommands=@($new.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-cin@('Set-PlatformPermissions','Assert-TrustAnchorPrivatePermissions')},$true)|Sort-Object{$_.Extent.StartOffset});if($permissionCommands.Count-ne4){return $false};$permissionRecords=@($permissionCommands|ForEach-Object{"$($_.GetCommandName())|$(@($_.CommandElements|ForEach-Object{$_.Extent.Text})-join' ')|$(Get-TestCleanupContext $_)"});$expectedPermission=@(
        'Set-PlatformPermissions|Set-PlatformPermissions -Lease $file -Policy @{Sddl="D:P(A;;FA;;;$sid)";ReadOnly=$false}|body',
        'Set-PlatformPermissions|Set-PlatformPermissions -Lease $file -Policy @{Mode=384}|body',
        'Assert-TrustAnchorPrivatePermissions|Assert-TrustAnchorPrivatePermissions $file|body',
        'Assert-TrustAnchorPrivatePermissions|Assert-TrustAnchorPrivatePermissions $file|body'
    );if(($permissionRecords-join"`n")-cne($expectedPermission-join"`n")-or$permissionCommands[2].Extent.StartOffset-ge$writes[0].Extent.StartOffset-or$permissionCommands[3].Extent.StartOffset-le$writes[0].Extent.StartOffset){return $false}
    $aclCalls=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$node.Static-and$node.Expression-is[Management.Automation.Language.TypeExpressionAst]-and$node.Expression.TypeName.FullName-ceq'SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector'},$true)|Sort-Object{$_.Extent.StartOffset});$aclRecords=@($aclCalls|ForEach-Object{"$(Get-TestAncestorFunctionName $_)|$($_.Member.Value)|$(@($_.Arguments|ForEach-Object{$_.Extent.Text})-join',')"});$expectedAcl=@(
        'Get-TrustAnchorMetadataEvidence|InspectMetadata|[Microsoft.Win32.SafeHandles.SafeFileHandle]$handle',
        'Get-TrustAnchorMetadataEvidence|Inspect|[Microsoft.Win32.SafeHandles.SafeFileHandle]$handle',
        'Remove-TrustAnchorCreatedFile|DeleteExact|$Lease.Path,[uint64]$Lease.Expected.Device,[uint64]$Lease.Expected.Inode'
    );if(($aclRecords-join"`n")-cne($expectedAcl-join"`n")){return $false}
    $metadata=$functions['Get-TrustAnchorMetadataEvidence'];$handleAssignments=@($metadata.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and$node.Left-is[Management.Automation.Language.VariableExpressionAst]-and$node.Left.VariablePath.UserPath-ceq'handle'},$true));if($handleAssignments.Count-ne1-or$handleAssignments[0].Right.Extent.Text-cne'Get-TrustAnchorLeaseHandle $Lease'){return $false}
    $permission=$functions['Assert-TrustAnchorPrivatePermissions'];$metadataCommands=@($permission.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Get-TrustAnchorMetadataEvidence'},$true));if($metadataCommands.Count-ne1-or$metadataCommands[0].CommandElements.Count-ne2-or$metadataCommands[0].CommandElements[1]-isnot[Management.Automation.Language.VariableExpressionAst]-or$metadataCommands[0].CommandElements[1].VariablePath.UserPath-cne'Lease'){return $false}
    return $true
}
function Test-TrustAnchorPrivateInputOperationSemantics {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    $records=[Collections.Generic.List[string]]::new()
    foreach($name in @('Open-TrustAnchorPrivateKeyLease','Read-TrustAnchorPrivateKeyLease','Open-TrustAnchorPrivateKey','Invoke-ConvertToTrustAnchorPublicKeyXmlAction','Invoke-GetTrustAnchorFingerprintAction')){
        $matches=@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true));if($matches.Count-ne1){return $false}
        foreach($node in @($matches[0].FindAll({param($item)$item-is[Management.Automation.Language.CommandAst]-or$item-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)|Sort-Object{$_.Extent.StartOffset})){
            if($node-is[Management.Automation.Language.CommandAst]){$records.Add("$name|Command|$($node.GetCommandName())|$(@($node.CommandElements|ForEach-Object{$_.Extent.Text})-join' ')")}else{$records.Add("$name|Member|$($node.Expression.Extent.Text)|$($node.Member.Value)|$(@($node.Arguments|ForEach-Object{$_.Extent.Text})-join',')")}
        }
    }
    $expected=@'
Open-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorPathEvidence|New-TrustAnchorPathEvidence -Path $Path -Purpose PrivateKey -Existing
Open-TrustAnchorPrivateKeyLease|Command|Open-PlatformFile|Open-PlatformFile -ParentLease $pathEvidence.ParentLease -Leaf $pathEvidence.Leaf -Access Read -CreateMode OpenExisting
Open-TrustAnchorPrivateKeyLease|Command|Assert-PlatformFileIdentity|Assert-PlatformFileIdentity -Lease $file -Expected $expected -SingleLink -VerifyPath
Open-TrustAnchorPrivateKeyLease|Command|Out-Null|Out-Null
Open-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError $_.Exception.Message 'TrustAnchor.PrivateIdentityChanged'
Open-TrustAnchorPrivateKeyLease|Command|Get-TrustAnchorMetadataEvidence|Get-TrustAnchorMetadataEvidence $file
Open-TrustAnchorPrivateKeyLease|Member|$file|Dispose|
Open-TrustAnchorPrivateKeyLease|Command|Close-TrustAnchorPathEvidence|Close-TrustAnchorPathEvidence $pathEvidence
Read-TrustAnchorPrivateKeyLease|Command|Get-TrustAnchorMetadataEvidence|Get-TrustAnchorMetadataEvidence $Lease.FileLease
Read-TrustAnchorPrivateKeyLease|Command|Assert-TrustAnchorPrivatePermissions|Assert-TrustAnchorPrivatePermissions $Lease.FileLease $before
Read-TrustAnchorPrivateKeyLease|Command|Out-Null|Out-Null
Read-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError $_.Exception.Message 'TrustAnchor.UnsafePrivatePermissions'
Read-TrustAnchorPrivateKeyLease|Command|Test-TrustAnchorMetadataEqual|Test-TrustAnchorMetadataEqual $Lease.OpenMetadata $before
Read-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError 'The private-key handle metadata changed after it was opened.' 'TrustAnchor.PrivateMetadataChanged'
Read-TrustAnchorPrivateKeyLease|Member|$Lease.FileLease|ReadAllBytes|1048576
Read-TrustAnchorPrivateKeyLease|Command|Assert-PlatformFileIdentity|Assert-PlatformFileIdentity -Lease $Lease.FileLease -Expected $Lease.Expected -SingleLink -VerifyPath
Read-TrustAnchorPrivateKeyLease|Command|Out-Null|Out-Null
Read-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError $_.Exception.Message 'TrustAnchor.PrivateIdentityChanged'
Read-TrustAnchorPrivateKeyLease|Command|Get-TrustAnchorMetadataEvidence|Get-TrustAnchorMetadataEvidence $Lease.FileLease
Read-TrustAnchorPrivateKeyLease|Command|Assert-TrustAnchorPrivatePermissions|Assert-TrustAnchorPrivatePermissions $Lease.FileLease $after
Read-TrustAnchorPrivateKeyLease|Command|Out-Null|Out-Null
Read-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError $_.Exception.Message 'TrustAnchor.UnsafePrivatePermissions'
Read-TrustAnchorPrivateKeyLease|Command|Test-TrustAnchorMetadataEqual|Test-TrustAnchorMetadataEqual $before $after
Read-TrustAnchorPrivateKeyLease|Command|New-TrustAnchorError|New-TrustAnchorError 'The private-key handle metadata changed while it was being read.' 'TrustAnchor.PrivateMetadataChanged'
Read-TrustAnchorPrivateKeyLease|Member|[Security.Cryptography.CryptographicOperations]|ZeroMemory|$bytes
Open-TrustAnchorPrivateKey|Command|Open-TrustAnchorPrivateKeyLease|Open-TrustAnchorPrivateKeyLease $Path
Open-TrustAnchorPrivateKey|Command|Read-TrustAnchorPrivateKeyLease|Read-TrustAnchorPrivateKeyLease $lease
Open-TrustAnchorPrivateKey|Command|Close-TrustAnchorPrivateKeyLease|Close-TrustAnchorPrivateKeyLease $lease
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Assert-TrustAnchorInteractiveHost|Assert-TrustAnchorInteractiveHost
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Assert-TrustAnchorKeyPath|Assert-TrustAnchorKeyPath -Path $OutputPath -Purpose PublicOutput
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Read-TrustAnchorInputBytes|Read-TrustAnchorInputBytes $PublicKeyPemPath
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Import-TrustAnchorPublicPem|Import-TrustAnchorPublicPem $inputBytes
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Assert-TrustAnchorPublicKey|Assert-TrustAnchorPublicKey $rsa
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|ConvertTo-TrustAnchorCanonicalXml|ConvertTo-TrustAnchorCanonicalXml $rsa
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|New-TrustAnchorKeyFile|New-TrustAnchorKeyFile -PathEvidence $target -Bytes $bytes
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Get-TrustAnchorFingerprint|Get-TrustAnchorFingerprint $rsa
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Close-TrustAnchorCreatedFile|Close-TrustAnchorCreatedFile $lease
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Command|Close-TrustAnchorPathEvidence|Close-TrustAnchorPathEvidence $target
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Member|[Security.Cryptography.CryptographicOperations]|ZeroMemory|$inputBytes
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Member|[Security.Cryptography.CryptographicOperations]|ZeroMemory|$bytes
Invoke-ConvertToTrustAnchorPublicKeyXmlAction|Member|$rsa|Dispose|
Invoke-GetTrustAnchorFingerprintAction|Command|Assert-TrustAnchorInteractiveHost|Assert-TrustAnchorInteractiveHost
Invoke-GetTrustAnchorFingerprintAction|Command|Where-Object|Where-Object {-not[string]::IsNullOrWhiteSpace($_)}
Invoke-GetTrustAnchorFingerprintAction|Member|[string]|IsNullOrWhiteSpace|$_
Invoke-GetTrustAnchorFingerprintAction|Member|[string]|IsNullOrWhiteSpace|$PublicKeyXmlPath
Invoke-GetTrustAnchorFingerprintAction|Command|Read-TrustAnchorInputBytes|Read-TrustAnchorInputBytes $PublicKeyXmlPath
Invoke-GetTrustAnchorFingerprintAction|Command|Import-TrustAnchorPublicXml|Import-TrustAnchorPublicXml $inputBytes
Invoke-GetTrustAnchorFingerprintAction|Member|[string]|IsNullOrWhiteSpace|$PublicKeyPemPath
Invoke-GetTrustAnchorFingerprintAction|Command|Read-TrustAnchorInputBytes|Read-TrustAnchorInputBytes $PublicKeyPemPath
Invoke-GetTrustAnchorFingerprintAction|Command|Import-TrustAnchorPublicPem|Import-TrustAnchorPublicPem $inputBytes
Invoke-GetTrustAnchorFingerprintAction|Command|Open-TrustAnchorPrivateKeyLease|Open-TrustAnchorPrivateKeyLease $EncryptedPrivateKeyPath
Invoke-GetTrustAnchorFingerprintAction|Command|Read-TrustAnchorPassword|Read-TrustAnchorPassword
Invoke-GetTrustAnchorFingerprintAction|Command|Read-TrustAnchorPrivateKeyLease|Read-TrustAnchorPrivateKeyLease $privateLease
Invoke-GetTrustAnchorFingerprintAction|Command|Import-TrustAnchorEncryptedPrivateKey|Import-TrustAnchorEncryptedPrivateKey -Bytes $inputBytes -Password $password
Invoke-GetTrustAnchorFingerprintAction|Command|Assert-TrustAnchorPublicKey|Assert-TrustAnchorPublicKey $rsa
Invoke-GetTrustAnchorFingerprintAction|Command|Get-TrustAnchorFingerprint|Get-TrustAnchorFingerprint $rsa
Invoke-GetTrustAnchorFingerprintAction|Member|[Security.Cryptography.CryptographicOperations]|ZeroMemory|$inputBytes
Invoke-GetTrustAnchorFingerprintAction|Command|Close-TrustAnchorPrivateKeyLease|Close-TrustAnchorPrivateKeyLease $privateLease
Invoke-GetTrustAnchorFingerprintAction|Member|$rsa|Dispose|
Invoke-GetTrustAnchorFingerprintAction|Member|$password|Dispose|
'@
    return ($records-join"`n")-ceq$expected.Trim()
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
    $statements=@($Ast.EndBlock.Statements);if($statements.Count-ne2-or$statements[0]-isnot[Management.Automation.Language.AssignmentStatementAst]-or$statements[1]-isnot[Management.Automation.Language.TryStatementAst]){return $false}
    $assignment=$statements[0];if($assignment.Left-isnot[Management.Automation.Language.VariableExpressionAst]-or$assignment.Left.VariablePath.UserPath-cne'module'){return $false}
    if($assignment.Right-isnot[Management.Automation.Language.PipelineAst]-or$assignment.Right.PipelineElements.Count-ne1-or$assignment.Right.PipelineElements[0]-isnot[Management.Automation.Language.CommandAst]){return $false}
    $import=$assignment.Right.PipelineElements[0];if($import.InvocationOperator-cne[Management.Automation.Language.TokenKind]::Unknown-or$import.GetCommandName()-cne'Microsoft.PowerShell.Core\Import-Module'){return $false}
    $importElements=@($import.CommandElements);if($importElements.Count-ne6){return $false}
    if($importElements[1]-isnot[Management.Automation.Language.ParenExpressionAst]-or$importElements[1].Pipeline.PipelineElements.Count-ne1-or$importElements[1].Pipeline.PipelineElements[0]-isnot[Management.Automation.Language.CommandExpressionAst]){return $false}
    $combine=$importElements[1].Pipeline.PipelineElements[0].Expression
    if($combine-isnot[Management.Automation.Language.InvokeMemberExpressionAst]-or-not$combine.Static-or$combine.Expression-isnot[Management.Automation.Language.TypeExpressionAst]-or$combine.Expression.TypeName.FullName-cne'IO.Path'-or$combine.Member.Value-cne'Combine'-or$combine.Arguments.Count-ne2){return $false}
    if($combine.Arguments[0]-isnot[Management.Automation.Language.VariableExpressionAst]-or$combine.Arguments[0].VariablePath.UserPath-cne'PSScriptRoot'-or$combine.Arguments[1]-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$combine.Arguments[1].Value-cne'TrustAnchorPrivateKey.psm1'){return $false}
    $try=$statements[1]
    $preGuardCommands=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.Extent.StartOffset-lt$try.Extent.StartOffset},$true));if($preGuardCommands.Count-ne1-or$preGuardCommands[0]-ne$import){return $false}
    $preGuardMembers=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$node.Extent.StartOffset-lt$try.Extent.StartOffset},$true));if($preGuardMembers.Count-ne1-or$preGuardMembers[0]-ne$combine){return $false}
    if($importElements[2]-isnot[Management.Automation.Language.CommandParameterAst]-or$importElements[2].ParameterName-cne'PassThru'){return $false}
    if($importElements[3]-isnot[Management.Automation.Language.CommandParameterAst]-or$importElements[3].ParameterName-cne'Force'){return $false}
    if($importElements[4]-isnot[Management.Automation.Language.CommandParameterAst]-or$importElements[4].ParameterName-cne'ErrorAction'-or$importElements[5]-isnot[Management.Automation.Language.StringConstantExpressionAst]-or$importElements[5].Value-cne'Stop'){return $false}
    if(@($try.Body.Statements).Count-ne1-or-not(Test-TestAstContract $try.Body.Statements[0] $Contract.TryTokenCount $Contract.TryNodeCount $Contract.TrySha256)){return $false}
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
            );InnerParameters=@('id|<none>','privatePath|<none>','publicPath|<none>');OuterArguments=@('KeyId','PrivateKeyPath','PublicKeyXmlPath');ActionArguments=@('KeyId=id','PrivateKeyPath=privatePath','PublicKeyXmlPath=publicPath');WholeTokenCount=110;WholeNodeCount=85;WholeSha256='3ef2e8d82bdff973914e75450a068046a201162f20c7f505c1df07a59b7471e5';TryTokenCount=24;TryNodeCount=30;TrySha256='31e3057472486f3ee6dc6e0cfecbb36a70b2e1ebf81d0a7addc718b2d0a0ed84'
        }
        'ConvertTo-TrustAnchorPublicKeyXml.ps1'=@{
            Action='Invoke-ConvertToTrustAnchorPublicKeyXmlAction';CmdletBinding='[CmdletBinding()]';Parameters=@(
                'PublicKeyPemPath|[Parameter(Mandatory)][string]',
                'OutputPath|[Parameter(Mandatory)][string]'
            );InnerParameters=@('inputPath|<none>','outputPath|<none>');OuterArguments=@('PublicKeyPemPath','OutputPath');ActionArguments=@('PublicKeyPemPath=inputPath','OutputPath=outputPath');WholeTokenCount=86;WholeNodeCount=71;WholeSha256='29d5c03fa588b9b216ab098c504119a38aad30aad21c59e596c0303e41cd9f44';TryTokenCount=19;TryNodeCount=25;TrySha256='71ecd62780be11717df10a16b44ec768af37f8b109b5f27bba14c3498a60263b'
        }
        'Get-TrustAnchorFingerprint.ps1'=@{
            Action='Invoke-GetTrustAnchorFingerprintAction';CmdletBinding="[CmdletBinding(DefaultParameterSetName='Xml')]";Parameters=@(
                "PublicKeyXmlPath|[Parameter(Mandatory,ParameterSetName='Xml')][string]",
                "PublicKeyPemPath|[Parameter(Mandatory,ParameterSetName='Pem')][string]",
                "EncryptedPrivateKeyPath|[Parameter(Mandatory,ParameterSetName='Private')][string]"
            );InnerParameters=@('xmlPath|<none>','pemPath|<none>','privatePath|<none>');OuterArguments=@('PublicKeyXmlPath','PublicKeyPemPath','EncryptedPrivateKeyPath');ActionArguments=@('PublicKeyXmlPath=xmlPath','PublicKeyPemPath=pemPath','EncryptedPrivateKeyPath=privatePath');WholeTokenCount=117;WholeNodeCount=90;WholeSha256='7350c7731989b4db1e4da6e1409b32ab31550a9906d88c25a5c6bcbb7936cdee';TryTokenCount=24;TryNodeCount=30;TrySha256='cdde2705e23f9b4451932a35af22391fa15d243c539569210f0de44711f1b71b'
        }
    }
}
function Test-TestCSharpSymbolInSet {
    param([Parameter(Mandatory)]$Symbol,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Symbols)
    foreach($candidate in $Symbols){if([Microsoft.CodeAnalysis.SymbolEqualityComparer]::Default.Equals($candidate,$Symbol)){return $true}};return $false
}
function Add-TestCSharpTaintedSymbol {
    param($Symbol,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Symbols)
    if($null-ne$Symbol-and-not(Test-TestCSharpSymbolInSet $Symbol $Symbols)){$Symbols.Add($Symbol);return $true};return $false
}
function Get-TestCSharpTargetSymbol {
    param($Operation)
    if($null-eq$Operation){return $null}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Conversion){return Get-TestCSharpTargetSymbol $Operation.Operand}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Argument){return Get-TestCSharpTargetSymbol $Operation.Value}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::LocalReference){return $Operation.Local}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::FieldReference){return $Operation.Field}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::ArrayElementReference){return Get-TestCSharpTargetSymbol $Operation.ArrayReference}
    return $null
}
function Test-TestCSharpOperationDependsOnTaint {
    param([Parameter(Mandatory)]$Operation,[Parameter(Mandatory)][string]$ParameterName,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$TaintedSymbols)
    foreach($item in Get-TestCSharpOperations $Operation){
        if($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::ParameterReference-and$item.Parameter.Name-ceq$ParameterName){return $true}
        if($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::LocalReference-and(Test-TestCSharpSymbolInSet $item.Local $TaintedSymbols)){return $true}
        if($item.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::FieldReference-and(Test-TestCSharpSymbolInSet $item.Field $TaintedSymbols)){return $true}
    }
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
        $byteParameters=@($method.ParameterList.Parameters|Where-Object{($analysis.Model.GetDeclaredSymbol($_).Type.ToString())-ceq'byte[]'}|ForEach-Object{$analysis.Model.GetDeclaredSymbol($_).Name});$tainted=[Collections.Generic.List[object]]::new();$operations=@(Get-TestCSharpOperations $bodyOperation);$changed=$true
        while($changed){
            $changed=$false
            foreach($candidate in $operations){
                if($candidate.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::VariableDeclarator-and$null-ne$candidate.Initializer-and@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnTaint $candidate.Initializer.Value $_ $tainted}).Count-gt0){if(Add-TestCSharpTaintedSymbol $candidate.Symbol $tainted){$changed=$true}}
                elseif($candidate.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::SimpleAssignment-and@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnTaint $candidate.Value $_ $tainted}).Count-gt0){if(Add-TestCSharpTaintedSymbol (Get-TestCSharpTargetSymbol $candidate.Target) $tainted){$changed=$true}}
                elseif($candidate.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation){
                    $copyTarget=$null;$copySource=$null
                    if($candidate.TargetMethod.ContainingType.ToString()-ceq'System.Array'-and$candidate.TargetMethod.Name-ceq'Copy'){$copySource=$candidate.Arguments[0].Value;$copyTarget=$candidate.Arguments[1].Value}
                    elseif($candidate.TargetMethod.ContainingType.ToString()-ceq'System.Buffer'-and$candidate.TargetMethod.Name-ceq'BlockCopy'){$copySource=$candidate.Arguments[0].Value;$copyTarget=$candidate.Arguments[2].Value}
                    if($null-ne$copyTarget-and@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnTaint $copySource $_ $tainted}).Count-gt0){if(Add-TestCSharpTaintedSymbol (Get-TestCSharpTargetSymbol $copyTarget) $tainted){$changed=$true}}
                    $sourceTainted=@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnTaint $candidate $_ $tainted}).Count-gt0
                    if($sourceTainted){foreach($argument in $candidate.Arguments){if($argument.Parameter.RefKind-cne[Microsoft.CodeAnalysis.RefKind]::None){if(Add-TestCSharpTaintedSymbol (Get-TestCSharpTargetSymbol $argument.Value) $tainted){$changed=$true}}}}
                }
            }
        }
        foreach($operation in Get-TestCSharpOperations $bodyOperation){
            if($operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation){
                $target=$operation.TargetMethod
                if($method.Identifier.ValueText-ceq'DecodePublicXml'-and$target.Name-ceq'RequirePublicXmlStructure'){$xmlValidator=$operation}
            }
            if($null-ne$operation.Type-and$operation.Type.SpecialType-ceq[Microsoft.CodeAnalysis.SpecialType]::System_String-and-not$operation.ConstantValue.HasValue){
                $sources=@($byteParameters|Where-Object{Test-TestCSharpOperationDependsOnTaint $operation $_ $tainted})
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
function Get-TestCSharpConditionOperandRecord {
    param([Parameter(Mandatory)]$Operation)
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Conversion){return Get-TestCSharpConditionOperandRecord $Operation.Operand}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::LocalReference){return "local:$($Operation.Local.Name)"}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::ParameterReference){return "parameter:$($Operation.Parameter.Name)"}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::FieldReference){return "field:$($Operation.Field.ContainingType.ToString()).$($Operation.Field.Name)"}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::PropertyReference){return "property:$($Operation.Property.Name)"}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Literal){return "literal:$($Operation.ConstantValue.Value)"}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation){return "call:$($Operation.TargetMethod.ContainingType.ToString()).$($Operation.TargetMethod.Name)("+(@($Operation.Arguments|ForEach-Object{Get-TestCSharpConditionOperandRecord $_.Value})-join',')+')'}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Unary){return "unary:$($Operation.OperatorKind)("+(Get-TestCSharpConditionOperandRecord $Operation.Operand)+')'}
    if($Operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Binary){return "binary:$($Operation.OperatorKind)("+(Get-TestCSharpConditionOperandRecord $Operation.LeftOperand)+','+(Get-TestCSharpConditionOperandRecord $Operation.RightOperand)+')'}
    return "unsupported:$($Operation.Kind)"
}
function Test-TrustAnchorDarwinAclSemantics {
    param([Parameter(Mandatory)][string]$CSharpSource)
    $analysis=Get-TrustAnchorCSharpAnalysis $CSharpSource;if($null-eq$analysis){return $false}
    $methods=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'AssertNoMacExtendedAcl'});if($methods.Count-ne1){return $false}
    $records=@($methods[0].DescendantNodes()|Where-Object{$_.GetType().Name-ceq'IfStatementSyntax'}|Sort-Object{$_.SpanStart}|ForEach-Object{$condition=$analysis.Model.GetOperation($_.Condition);$returns=@($_.Statement.DescendantNodesAndSelf()|Where-Object{$_.GetType().Name-ceq'ReturnStatementSyntax'}).Count;$throws=@($_.Statement.DescendantNodesAndSelf()|Where-Object{$_.GetType().Name-ceq'ThrowStatementSyntax'}).Count;"$(Get-TestCSharpConditionOperandRecord $condition)|$(Get-TestCleanupContext $_)|$returns|$throws"})
    $expected=@'
unary:Not(property:Mac)|body|1|0
binary:Equals(local:acl,field:nint.Zero)|body|1|1
binary:Equals(local:error,literal:2)|body|1|0
binary:Equals(local:result,literal:0)|body|0|1
binary:ConditionalOr(binary:Equals(local:error,literal:2),binary:Equals(local:error,literal:22))|body|1|0
binary:NotEquals(call:SyuanTsai.AIInstructions.TrustAnchor.UnixRollbackLease.acl_free(local:acl),literal:0)|finally|0|1
'@
    return ($records-join"`n")-ceq$expected.Trim()
}
function Get-TestAncestorFunctionName {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $parent=$Node.Parent
    while($null-ne$parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){return $parent.Name};$parent=$parent.Parent}
    return $null
}
function Get-TrustAnchorSensitiveFunctionContracts {
    return @{
        'Assert-TrustAnchorInteractiveHost'=@{TokenCount=86;NodeCount=73;Sha256='0fe57642a9ab0c8eedf32d93c9ba0dac77892e475db99ba00d5f6d65d478b262'}
        'Use-TrustAnchorPassword'=@{TokenCount=175;NodeCount=127;Sha256='220b44c28a28ce17d62a7392aa1fc1f17daab61168d78a8a832d2955544c072d'}
        'Read-TrustAnchorPassword'=@{TokenCount=143;NodeCount=135;Sha256='45c7f0bf0cfac8687b5d3a597a96dfe6605417844acb10da3bf4735141238914'}
        'Invoke-NewTrustAnchorKeyPairAction'=@{TokenCount=301;NodeCount=300;Sha256='ebb92a094a9fa545a5ed0ae5f6de97ca890131df531ab1f862cbe2bd8c1e13fe'}
        'Invoke-ConvertToTrustAnchorPublicKeyXmlAction'=@{TokenCount=138;NodeCount=134;Sha256='e9ac0c1f60fe96f1ef0eb4c387352af72c5b4c0121232cd65a85f2a32c403a2f'}
        'Invoke-GetTrustAnchorFingerprintAction'=@{TokenCount=201;NodeCount=194;Sha256='e5c9417351771c2ffaf6a8edebd15a5263bb23e38e4aff822365286261a1cbbf'}
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
10|Assert-PlatformFileIdentity
3|Assert-TrustAnchorInteractiveHost
3|Assert-TrustAnchorKeyPath
1|Assert-TrustAnchorOutsideWorktree
4|Assert-TrustAnchorPrivatePermissions
3|Assert-TrustAnchorPublicKey
3|Close-TrustAnchorCreatedFile
5|Close-TrustAnchorPathEvidence
2|Close-TrustAnchorPrivateKeyLease
2|ConvertTo-Json
3|ConvertTo-TrustAnchorCanonicalXml
1|Export-TrustAnchorEncryptedPrivateKey
1|Get-Command
3|Get-TrustAnchorFingerprint
3|Get-TrustAnchorLeaseHandle
4|Get-TrustAnchorMetadataEvidence
1|Get-TrustAnchorPhysicalParent
1|git
1|Import-TrustAnchorEncryptedPrivateKey
2|Import-TrustAnchorPublicPem
1|Import-TrustAnchorPublicXml
2|Join-Path
1|Microsoft.PowerShell.Core\Export-ModuleMember
1|Microsoft.PowerShell.Core\Import-Module
1|Microsoft.PowerShell.Core\Set-StrictMode
1|Microsoft.PowerShell.Utility\Add-Type
2|Microsoft.PowerShell.Utility\Read-Host
17|New-TrustAnchorError
3|New-TrustAnchorKeyFile
2|New-TrustAnchorPathEvidence
1|Open-PlatformDirectory
2|Open-PlatformFile
2|Open-TrustAnchorPrivateKeyLease
16|Out-Null
3|Read-TrustAnchorInputBytes
2|Read-TrustAnchorPassword
2|Read-TrustAnchorPrivateKeyLease
1|Remove-TrustAnchorCreatedFile
1|Resolve-PlatformPhysicalPath
2|Set-PlatformPermissions
2|Split-Path
2|Test-TrustAnchorMetadataEqual
4|Use-TrustAnchorPassword
2|Where-Object
'@
    if(-not(Test-ExactInventory $commandNames $expectedCommands)){return $false}
    $readHost=@($commands|Where-Object{$_.GetCommandName()-ceq'Microsoft.PowerShell.Utility\Read-Host'})
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
22|instance|System.Object|Dispose
1|instance|System.Object|EndsWith
2|instance|System.Object|ExportParameters
1|instance|System.Object|ExportSubjectPublicKeyInfo
1|instance|System.Object|Free
2|instance|System.Object|GetBytes
1|instance|System.Object|GetField
1|instance|System.Object|GetType
1|instance|System.Object|GetValue
1|instance|System.Object|ImportParameters
1|instance|System.Object|Invoke
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
1|static|IO.Path|Combine
1|static|IO.Path|GetFileName
7|static|IO.Path|GetFullPath
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
9|IO.Path
1|Management.Automation.ErrorCategory
1|Management.Automation.ErrorRecord
2|Microsoft.Win32.SafeHandles.SafeFileHandle
5|ordered
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
30|string
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
function Test-TestExactSingleVariableCondition {
    param([Parameter(Mandatory)]$Condition,[Parameter(Mandatory)][string]$Name)
    if($Condition-isnot[Management.Automation.Language.PipelineAst]-or$Condition.PipelineElements.Count-ne1){return $false}
    $expression=$Condition.PipelineElements[0];if($expression-isnot[Management.Automation.Language.CommandExpressionAst]){return $false}
    return $expression.Expression-is[Management.Automation.Language.VariableExpressionAst]-and$expression.Expression.VariablePath.UserPath-ceq$Name
}
function Get-TestNearestEnclosingIfCondition {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $cursor=$Node.Parent
    while($null-ne$cursor){
        if($cursor-is[Management.Automation.Language.IfStatementAst]){foreach($clause in $cursor.Clauses){if($Node.Extent.StartOffset-ge$clause.Item2.Extent.StartOffset-and$Node.Extent.EndOffset-le$clause.Item2.Extent.EndOffset){return $clause.Item1}}}
        $cursor=$cursor.Parent
    }
    return $null
}
function Test-TestNativeRegistrationAst {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    $allIts=@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'It'},$true));$describes=@($Ast.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Describe'},$true))
    $windowsDescribe=@($describes|Where-Object{[string]$_.CommandElements[1].Value-ceq'PR-K1 Windows native handle safety'});$unixDescribe=@($describes|Where-Object{[string]$_.CommandElements[1].Value-ceq'PR-K1 Unix native handle safety'});if($windowsDescribe.Count-ne1-or$unixDescribe.Count-ne1){return $false}
    $outers=@($Ast.FindAll({param($node)if($node-isnot[Management.Automation.Language.IfStatementAst]){return $false};return $windowsDescribe[0].Extent.StartOffset-ge$node.Extent.StartOffset-and$windowsDescribe[0].Extent.EndOffset-le$node.Extent.EndOffset-and$unixDescribe[0].Extent.StartOffset-ge$node.Extent.StartOffset-and$unixDescribe[0].Extent.EndOffset-le$node.Extent.EndOffset},$true));if($outers.Count-ne1-or-not(Test-TestExactSingleVariableCondition $outers[0].Clauses[0].Item1 'IsWindows')){return $false}
    $expected=@{InterT68_rejects_a_Linux_named_user_writable_parent_ACL='IsLinux';InterT69_rejects_a_macOS_extended_parent_ACL='IsMacOS';InterT70_creates_a_key_under_a_macOS_parent_without_an_extended_ACL='IsMacOS'}
    foreach($entry in $expected.GetEnumerator()){$matches=@($allIts|Where-Object{[string]$_.CommandElements[1].Value-ceq$entry.Key});if($matches.Count-ne1){return $false};$condition=Get-TestNearestEnclosingIfCondition $matches[0];if($null-eq$condition-or-not(Test-TestExactSingleVariableCondition $condition $entry.Value)){return $false}}
    return $true
}
function Get-TestCompleteOperationInventory {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,[string]$DriverSource=(Get-TestCliDriverSource))
    $raw=[Collections.Generic.List[string]]::new();$sources=[Collections.Generic.Queue[object]]::new();$sources.Enqueue([pscustomobject]@{Name='TestFile';Ast=$Ast;Purpose='TestScenarioOrHelper'})
    $driverTokens=$null;$driverErrors=$null;$driverAst=[Management.Automation.Language.Parser]::ParseInput($DriverSource,[ref]$driverTokens,[ref]$driverErrors);if(@($driverErrors).Count-ne0){return $null};$sources.Enqueue([pscustomobject]@{Name='Driver';Ast=$driverAst;Purpose='FormalCliTransport'})
    while($sources.Count-gt0){
        $source=$sources.Dequeue();$payloadOrdinal=0
        foreach($node in @($source.Ast.FindAll({param($item)$item-is[Management.Automation.Language.CommandAst]-or$item-is[Management.Automation.Language.InvokeMemberExpressionAst]-or$item-is[Management.Automation.Language.ConvertExpressionAst]},$true)|Sort-Object{$_.Extent.StartOffset})){
            $scope=Get-TestAncestorScopeName $node;$purpose=switch -CaseSensitive($scope){'Write-TestPrivateKeyFixture'{'PrivateFixturePermissionFirst';break}'Get-TestCliDriverSource'{'FormalCliTransportSource';break}default{$source.Purpose}}
            if($node-is[Management.Automation.Language.CommandAst]){
                $name=$node.GetCommandName();if([string]::IsNullOrEmpty($name)){$name='<dynamic>'};$parameters=@($node.CommandElements|Where-Object{$_-is[Management.Automation.Language.CommandParameterAst]}|ForEach-Object{$_.ParameterName});$raw.Add("$($source.Name)|$scope|PSCommand|$name|Parameters=$($parameters-join',')|Elements=$($node.CommandElements.Count)|Purpose=$purpose")
                if($node.InvocationOperator-cin@([Management.Automation.Language.TokenKind]::Ampersand,[Management.Automation.Language.TokenKind]::Dot)){$target=if($node.CommandElements.Count-eq0){'<none>'}else{(Get-CompactAstText $node.CommandElements[0])};$raw.Add("$($source.Name)|$scope|PSInvocationOperator|$($node.InvocationOperator)|Target=$target|Purpose=$purpose")}
                continue
            }
            if($node-is[Management.Automation.Language.InvokeMemberExpressionAst]){
                $receiver=if($node.Static-and$node.Expression-is[Management.Automation.Language.TypeExpressionAst]){$node.Expression.TypeName.FullName}else{Get-CompactAstText $node.Expression};$member=if($node.Member-is[Management.Automation.Language.StringConstantExpressionAst]){[string]$node.Member.Value}else{Get-CompactAstText $node.Member};$mode=if($node.Static){'Static'}else{'Instance'};$raw.Add("$($source.Name)|$scope|PSMember|$mode|Receiver=$receiver|Member=$member|Arguments=$($node.Arguments.Count)|Purpose=$purpose")
                if($node.Static-and$member-ceq'new'){$raw.Add("$($source.Name)|$scope|PSNew|Type=$receiver|Arguments=$($node.Arguments.Count)|Purpose=$purpose")}
                if($member-ceq'AddScript'-and$node.Arguments.Count-eq1-and$node.Arguments[0]-is[Management.Automation.Language.StringConstantExpressionAst]){$nestedTokens=$null;$nestedErrors=$null;$nestedAst=[Management.Automation.Language.Parser]::ParseInput([string]$node.Arguments[0].Value,[ref]$nestedTokens,[ref]$nestedErrors);if(@($nestedErrors).Count-ne0){return $null};$sources.Enqueue([pscustomobject]@{Name="$($source.Name)/AddScript$payloadOrdinal";Ast=$nestedAst;Purpose='ApprovedAddScriptPayload'});$payloadOrdinal++}
                continue
            }
            $raw.Add("$($source.Name)|$scope|PSCast|Type=$($node.Type.TypeName.FullName)|Child=$($node.Child.GetType().Name)|Purpose=$purpose")
        }
        foreach($stringNode in @($source.Ast.FindAll({param($item)$item-is[Management.Automation.Language.StringConstantExpressionAst]-and$item.Extent.Text.Length-ge4-and($item.Extent.Text.Substring(0,2)-cin@("@'",'@"'))},$true)|Sort-Object{$_.Extent.StartOffset})){
            $tree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([string]$stringNode.Value);if(@($tree.GetDiagnostics()|Where-Object Severity -eq ([Microsoft.CodeAnalysis.DiagnosticSeverity]::Error)).Count-ne0){continue};$scope=Get-TestAncestorScopeName $stringNode
            foreach($csharp in @($tree.GetRoot().DescendantNodes()|Where-Object{$_.GetType().Name-cin@('InvocationExpressionSyntax','ObjectCreationExpressionSyntax','ImplicitObjectCreationExpressionSyntax')}|Sort-Object SpanStart)){
                if($csharp.GetType().Name-ceq'InvocationExpressionSyntax'){$raw.Add("$($source.Name)|$scope|CSharpInvocation|Expression=$(($csharp.Expression.ToString()-replace'\s',''))|Arguments=$($csharp.ArgumentList.Arguments.Count)|Purpose=TransportBoundaryCSharp")}
                else{$type=if($csharp.GetType().Name-ceq'ImplicitObjectCreationExpressionSyntax'){'<implicit>'}else{($csharp.Type.ToString()-replace'\s','')};$raw.Add("$($source.Name)|$scope|CSharpObjectCreation|Type=$type|Arguments=$($csharp.ArgumentList.Arguments.Count)|Purpose=TransportBoundaryCSharp")}
            }
        }
    }
    $records=@($raw|Group-Object|Sort-Object Name|ForEach-Object{"$($_.Name)|Count=$($_.Count)"});return [pscustomobject]@{Records=$records;RecordCount=$records.Count;OperationCount=$raw.Count;Sha256=(Get-TestSha256Text ($records-join"`n"))}
}
function Test-TestCompleteOperationContract {
    param([Parameter(Mandatory)]$Inventory)
    return $null-ne$Inventory-and$Inventory.RecordCount-eq1650-and$Inventory.OperationCount-eq2981-and$Inventory.Sha256-ceq'b56cc69147e9eacbd3b80dc4487a14fae949c0f8f4a88167e980ffeb460c23ef'
}
function Get-TestRuntimeModuleScriptBlockCalls {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,[string]$DriverSource=(Get-TestCliDriverSource))
    return ,(Get-TestCompleteOperationInventory $Ast $DriverSource).Records
}
function Get-TestAncestorItName {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $cursor=$Node.Parent;while($null-ne$cursor){if($cursor-is[Management.Automation.Language.ScriptBlockAst]-and$cursor.Parent-is[Management.Automation.Language.ScriptBlockExpressionAst]-and$cursor.Parent.Parent-is[Management.Automation.Language.CommandAst]-and$cursor.Parent.Parent.GetCommandName()-ceq'It'){return [string]$cursor.Parent.Parent.CommandElements[1].Value};$cursor=$cursor.Parent};return '<none>'
}
function Get-TestAncestorScopeName {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $it=Get-TestAncestorItName $Node;if($it-cne'<none>'){return $it};$cursor=$Node.Parent;while($null-ne$cursor){if($cursor-is[Management.Automation.Language.FunctionDefinitionAst]){return $cursor.Name};$cursor=$cursor.Parent};return '<script>'
}
function Get-TestPrivateFixtureHelperInventory {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast)
    return ,(Get-TestCompleteOperationInventory $Ast).Records
}
function Get-TestFileWriteOperationInventory {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,[string]$DriverSource=(Get-TestCliDriverSource))
    return ,(Get-TestCompleteOperationInventory $Ast $DriverSource).Records
}

Describe 'PR-K1 trust-anchor cryptography contract' {
    # Scenario: A fresh 3072-bit RSA key is exported and its EncryptedPrivateKeyInfo ASN.1 is parsed independently.
    # Purpose: Prove the artifact itself uses PBES2, PBKDF2-HMAC-SHA256, AES-256-CBC, and 600000 iterations.
    It 'UnitT01_exports_the_exact_encrypted_PKCS8_profile_and_round_trips' {
        $secretSpec=New-TestSecretSpec;$passwordText=Get-TestSecretText $secretSpec.Seed $secretSpec.Length;$privatePath=Join-Path $TestDrive 'profile-private.pem';$publicPath=Join-Path $TestDrive 'profile-public.xml';$privateRsa=[Security.Cryptography.RSA]::Create();$publicRsa=[Security.Cryptography.RSA]::Create()
        try{
            $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$privatePath;PublicKeyXmlPath=$publicPath} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $false;$result.InteractiveState.InputRedirected|Should Be $false;$result.InteractiveState.UserInteractive|Should Be $true
            $pem=[IO.File]::ReadAllText($privatePath);$profile=Read-TestEncryptedPrivateKeyProfile $pem
            $profile.pbes2|Should Be '1.2.840.113549.1.5.13';$profile.kdf|Should Be '1.2.840.113549.1.5.12';$profile.prf|Should Be '1.2.840.113549.2.9';$profile.cipher|Should Be '2.16.840.1.101.3.4.1.42'
            $profile.iterations|Should Be 600000;$profile.ivLength|Should Be 16;($profile.saltLength -ge 16)|Should Be $true;($profile.encryptedLength -gt 0)|Should Be $true
            $privateRsa.ImportFromEncryptedPem($pem,$passwordText);$publicRsa.FromXmlString([IO.File]::ReadAllText($publicPath));[Convert]::ToHexString($privateRsa.ExportSubjectPublicKeyInfo())|Should Be ([Convert]::ToHexString($publicRsa.ExportSubjectPublicKeyInfo()));Assert-TestSentinelAbsentFromCliSurfaces $result $passwordText @($publicPath)
        }finally{$publicRsa.Dispose();$privateRsa.Dispose()}
    }

    # Scenario: Runtime-generated encrypted PKCS#8 inputs vary cipher, PRF, or iteration count one dimension at a time.
    # Purpose: Reject every encrypted-key profile outside the exact approved profile before decryption.
    It 'UnitT02_rejects_wrong_cipher_PRF_or_iteration_count' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$secretSpec=New-TestSecretSpec;$passwordText=Get-TestSecretText $secretSpec.Seed $secretSpec.Length;[char[]]$characters=$passwordText.ToCharArray();$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1';$index=0
        try{
            $profiles=@(
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes128Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA512,600000),
                [Security.Cryptography.PbeParameters]::new([Security.Cryptography.PbeEncryptionAlgorithm]::Aes256Cbc,[Security.Cryptography.HashAlgorithmName]::SHA256,599999)
            )
            foreach($profile in $profiles){$path=Join-Path $TestDrive "wrong-profile-$index.pem";[byte[]]$value=ConvertTo-TestUtf8Bytes ($rsa.ExportEncryptedPkcs8PrivateKeyPem($characters,$profile));try{Write-TestPrivateKeyFixture $path $value;$result=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$path} @($secretSpec);$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat';Assert-TestSentinelAbsentFromCliSurfaces $result $passwordText}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)};$index++}
        }finally{[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters);$rsa.Dispose()}
    }

    # Scenario: Unencrypted PKCS#1, unencrypted PKCS#8, XML private-key, and PKCS#12-shaped inputs reach the importer.
    # Purpose: Only encrypted PKCS#8 PEM may cross the private-key import boundary and failures retain the required error ID.
    It 'UnitT03_rejects_every_unsupported_private_key_format' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$secretSpec=New-TestSecretSpec;$passwordText=Get-TestSecretText $secretSpec.Seed $secretSpec.Length;$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1';$index=0
        try{foreach($fixture in @($rsa.ExportRSAPrivateKeyPem(),$rsa.ExportPkcs8PrivateKeyPem(),'<RSAKeyValue><D>AQ==</D></RSAKeyValue>',[Convert]::ToBase64String([byte[]](1,2,3,4)))){[byte[]]$value=ConvertTo-TestUtf8Bytes $fixture;$path=Join-Path $TestDrive "unsupported-private-$index.pem";try{Write-TestPrivateKeyFixture $path $value;$result=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$path} @($secretSpec);$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat';Assert-TestSentinelAbsentFromCliSurfaces $result $passwordText}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($value)};$index++}}finally{$rsa.Dispose()}
    }

    # Scenario: Canonical XML is produced twice from the same public key and parsed back.
    # Purpose: Preserve UTF-8-without-BOM, one LF, no CR, and stable canonical bytes.
    It 'UnitT04_emits_stable_canonical_XML_bytes' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$copy=[Security.Cryptography.RSA]::Create();$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1'
        try{$pemPath=Join-Path $TestDrive 'canonical.pem';$firstPath=Join-Path $TestDrive 'canonical-first.xml';$secondPath=Join-Path $TestDrive 'canonical-second.xml';[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$pemPath;OutputPath=$firstPath}).HadErrors|Should Be $false;(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$pemPath;OutputPath=$secondPath}).HadErrors|Should Be $false;[byte[]]$first=[IO.File]::ReadAllBytes($firstPath);[byte[]]$second=[IO.File]::ReadAllBytes($secondPath);$first[0..2]|Should Not Be @(0xef,0xbb,0xbf);$first|Should Not Contain 13;$first[-1]|Should Be 10;$first[-2]|Should Not Be 10;[Convert]::ToHexString($second)|Should Be ([Convert]::ToHexString($first));$copy.FromXmlString([IO.File]::ReadAllText($firstPath));[Convert]::ToHexString($copy.ExportSubjectPublicKeyInfo())|Should Be ([Convert]::ToHexString($rsa.ExportSubjectPublicKeyInfo()))}finally{$copy.Dispose();$rsa.Dispose()}
    }

    # Scenario: Fingerprints are calculated independently from canonical XML and SPKI DER.
    # Purpose: Bind both published fingerprint representations to their exact bytes.
    It 'UnitT05_calculates_XML_and_SPKI_SHA256' {
        $rsa=[Security.Cryptography.RSA]::Create(3072)
        try{$pemPath=Join-Path $TestDrive 'hash.pem';[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());$actual=(Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{PublicKeyPemPath=$pemPath}).Output[0];[byte[]]$xml=ConvertTo-TestCanonicalXmlBytes $rsa;$actual.xmlSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xml)).ToLowerInvariant());$actual.spkiSha256|Should Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant())}finally{$rsa.Dispose()}
    }

    # Scenario: A 2048-bit key and a 3072-bit exponent-3 key reach the public-key assertion.
    # Purpose: Enforce both minimum modulus length and exponent 65537.
    It 'UnitT06_rejects_weak_RSA_profiles' {
        $weak=[Security.Cryptography.RSA]::Create(2048);$source=[Security.Cryptography.RSA]::Create(3072);$wrongExponent=[Security.Cryptography.RSA]::Create();$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1'
        try{$parameters=$source.ExportParameters($false);$parameters.Exponent=[byte[]](3);$wrongExponent.ImportParameters($parameters);$index=0;foreach($rsa in @($weak,$wrongExponent)){$pemPath=Join-Path $TestDrive "weak-profile-$index.pem";[IO.File]::WriteAllText($pemPath,$rsa.ExportSubjectPublicKeyInfoPem());(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$pemPath;OutputPath=(Join-Path $TestDrive "weak-profile-$index.xml")}).HadErrors|Should Be $true;$index++}}finally{$wrongExponent.Dispose();$source.Dispose();$weak.Dispose()}
    }

    # Scenario: A valid encrypted PKCS#8 fixture uses the approved algorithms and password but a one-byte PBKDF2 salt.
    # Purpose: Reject decryptable encrypted keys whose offline-password salt is below sixteen bytes.
    It 'UnitT07_rejects_a_decryptable_private_key_with_a_short_PBKDF2_salt' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$secretSpec=New-TestSecretSpec;$passwordText=Get-TestSecretText $secretSpec.Seed $secretSpec.Length;[byte[]]$passwordBytes=ConvertTo-TestUtf8Bytes $passwordText;$fixture=$null;[char[]]$characters=$passwordText.ToCharArray();[byte[]]$pemBytes=$null
        try{$fixture=New-TestShortSaltEncryptedPrivateKey $rsa $passwordBytes;[SyuanTsai.AIInstructions.TrustAnchor.Tests.CryptoProbe]::CanDecrypt($fixture.Der,$characters)|Should Be $true;$pemBytes=ConvertTo-TestUtf8Bytes $fixture.Pem;$path=Join-Path $TestDrive 'short-salt.pem';Write-TestPrivateKeyFixture $path $pemBytes;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @($secretSpec);$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat';Assert-TestSentinelAbsentFromCliSurfaces $result $passwordText}finally{if($null-ne$passwordBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes)};if($null-ne$pemBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($pemBytes)};if($null-ne$fixture){[Security.Cryptography.CryptographicOperations]::ZeroMemory([byte[]]$fixture.Der)};[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($characters);$rsa.Dispose()}
    }
}

Describe 'PR-K1 password and public command boundary' {
    # Scenario: Read-Host returns a fifteen-character password.
    # Purpose: Bind the rejection boundary exactly below sixteen characters.
    It 'UnitT08_rejects_a_fifteen_character_password' {
        $private=Join-Path $TestDrive 'weak-private.pem';$public=Join-Path $TestDrive 'weak-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestSecretSpec -Length 15))
        $result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.WeakPassword';$result.ReadCount|Should Be 1
    }

    # Scenario: Read-Host returns a sixteen-character password.
    # Purpose: Bind the acceptance boundary exactly at sixteen characters.
    It 'UnitT09_accepts_a_sixteen_character_password' {
        $secretSpec=New-TestSecretSpec -Length 16;$private=Join-Path $TestDrive 'minimum-private.pem';$public=Join-Path $TestDrive 'minimum-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec)
        $result.HadErrors|Should Be $false;$result.ReadCount|Should Be 2;(Test-Path -LiteralPath $private)|Should Be $true
    }

    # Scenario: Two valid-length interactive password responses differ.
    # Purpose: Refuse a mistyped confirmation without converting either secret to a managed string.
    It 'UnitT10_rejects_mismatched_password_confirmation' {
        $private=Join-Path $TestDrive 'mismatch-private.pem';$public=Join-Path $TestDrive 'mismatch-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @((New-TestSecretSpec -Seed 11 -Length 20),(New-TestSecretSpec -Seed 12 -Length 20))
        $result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.PasswordMismatch';$result.ReadCount|Should Be 2
    }

    # Scenario: Two valid-length interactive password responses match.
    # Purpose: Return the confirmed SecureString for the caller to dispose.
    It 'UnitT11_accepts_matching_password_confirmation' {
        $secretSpec=New-TestSecretSpec -Seed 13 -Length 20;$private=Join-Path $TestDrive 'matching-private.pem';$public=Join-Path $TestDrive 'matching-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec)
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
        param($Marker)$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{PublicKeyXmlPath=(Join-Path $TestDrive 'missing.xml')} -CiMarker $Marker
        $result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.NonInteractive';$result.InteractiveState.InputRedirected|Should Be $false;$result.InteractiveState.UserInteractive|Should Be $true
    }

    # Scenario: The fingerprint CLI is launched with redirected stdin and no CI marker.
    # Purpose: A non-interactive pipe must fail before reading any key path and report TrustAnchor.NonInteractive.
    It 'InterT17_rejects_redirected_stdin_with_the_required_error_ID' {
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$info.ArgumentList.Add('-NoProfile');$info.ArgumentList.Add('-File');$info.ArgumentList.Add((Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'));$info.ArgumentList.Add('-PublicKeyXmlPath');$info.ArgumentList.Add((Join-Path $TestDrive 'missing.xml'));$info.RedirectStandardInput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false;foreach($marker in @('CI','GITHUB_ACTIONS','TF_BUILD','BUILD_BUILDID','RUNNER_TEMP')){$info.Environment.Remove($marker)|Out-Null}
        $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Close();$process.WaitForExit();try{$process.ExitCode|Should Not Be 0;$process.StandardError.ReadToEnd()|Should Match 'TrustAnchor\.NonInteractive'}finally{$process.Dispose()}
    }

    # Scenario: Runtime public and private PEM inputs exercise the conversion CLI in a real child console.
    # Purpose: Produce canonical XML while rejecting private PEM and weak public keys through the same action used by the formal CLI.
    It 'InterT18_converts_public_PEM_and_rejects_private_or_weak_inputs' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$weak=[Security.Cryptography.RSA]::Create(2048)
        [byte[]]$privateDer=$null;[char[]]$privateCharacters=$null;[byte[]]$privateBytes=$null
        try{
            $cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1';$publicPath=Join-Path $TestDrive 'public.pem';$outputPath=Join-Path $TestDrive 'public.xml';[IO.File]::WriteAllText($publicPath,$rsa.ExportSubjectPublicKeyInfoPem());$result=Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$publicPath;OutputPath=$outputPath};$result.HadErrors|Should Be $false;[Convert]::ToHexString([IO.File]::ReadAllBytes($outputPath))|Should Be ([Convert]::ToHexString((ConvertTo-TestCanonicalXmlBytes $rsa)))
            $privatePath=Join-Path $TestDrive 'private-input.pem';$privateDer=$rsa.ExportPkcs8PrivateKey();[char[]]$begin='-----BEGIN ';[char[]]$end='-----END ';[char[]]$keyLabel='PRIVATE KEY-----';$base64Length=[int](4*[Math]::Ceiling($privateDer.Length/3.0));$privateCharacters=[char[]]::new($begin.Length+$keyLabel.Length+1+$base64Length+1+$end.Length+$keyLabel.Length+1);$offset=0;[Array]::Copy($begin,0,$privateCharacters,$offset,$begin.Length);$offset+=$begin.Length;[Array]::Copy($keyLabel,0,$privateCharacters,$offset,$keyLabel.Length);$offset+=$keyLabel.Length;$privateCharacters[$offset++]=[char]10;$written=[Convert]::ToBase64CharArray($privateDer,0,$privateDer.Length,$privateCharacters,$offset);if($written-ne$base64Length){throw 'The PKCS#8 PEM fixture base64 length was not exact.'};$offset+=$written;$privateCharacters[$offset++]=[char]10;[Array]::Copy($end,0,$privateCharacters,$offset,$end.Length);$offset+=$end.Length;[Array]::Copy($keyLabel,0,$privateCharacters,$offset,$keyLabel.Length);$offset+=$keyLabel.Length;$privateCharacters[$offset]=[char]10;$privateBytes=[Text.UTF8Encoding]::new($false).GetBytes($privateCharacters);Write-TestPrivateKeyFixture $privatePath $privateBytes
            $rejected=Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$privatePath;OutputPath=(Join-Path $TestDrive 'private.xml')};$rejected.HadErrors|Should Be $true;$rejected.ErrorIds[0]|Should Be 'TrustAnchor.UnsupportedKeyFormat';$weakPath=Join-Path $TestDrive 'weak.pem';[IO.File]::WriteAllText($weakPath,$weak.ExportSubjectPublicKeyInfoPem());(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$weakPath;OutputPath=(Join-Path $TestDrive 'weak.xml')}).HadErrors|Should Be $true
        }finally{if($null-ne$privateDer){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateDer);if(@($privateDer|Where-Object{$_-ne[byte]0}).Count-ne0){throw 'The PKCS#8 DER fixture buffer was not cleared.'}};if($null-ne$privateCharacters){[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero($privateCharacters);if(@($privateCharacters|Where-Object{$_-ne[char]0}).Count-ne0){throw 'The PKCS#8 PEM character buffer was not cleared.'}};if($null-ne$privateBytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($privateBytes);if(@($privateBytes|Where-Object{$_-ne[byte]0}).Count-ne0){throw 'The PKCS#8 PEM byte buffer was not cleared.'}};$weak.Dispose();$rsa.Dispose()}
    }

    # Scenario: Canonical XML, PUBLIC KEY PEM, and an encrypted private key all represent the same runtime-generated RSA key.
    # Purpose: Exercise all fingerprint CLI orchestration paths while the private-key password still comes only from Read-Host.
    It 'InterT19_fingerprints_XML_public_PEM_and_encrypted_private_PEM' {
        $secretSpec=New-TestSecretSpec;$passwordText=Get-TestSecretText $secretSpec.Seed $secretSpec.Length;$publicRsa=[Security.Cryptography.RSA]::Create();$privatePath=Join-Path $TestDrive 'fingerprint-private.pem';$xmlPath=Join-Path $TestDrive 'fingerprint.xml'
        try{$created=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$privatePath;PublicKeyXmlPath=$xmlPath} @($secretSpec,$secretSpec);$created.HadErrors|Should Be $false;$publicRsa.FromXmlString([IO.File]::ReadAllText($xmlPath));[byte[]]$canonical=ConvertTo-TestCanonicalXmlBytes $publicRsa;$expected=[pscustomobject]@{xmlSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canonical)).ToLowerInvariant();spkiSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($publicRsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()};$pemPath=Join-Path $TestDrive 'fingerprint.pem';[IO.File]::WriteAllText($pemPath,$publicRsa.ExportSubjectPublicKeyInfoPem());$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1';$xml=(Invoke-TestTrustAnchorCli $cli @{PublicKeyXmlPath=$xmlPath}).Output[0];$pem=(Invoke-TestTrustAnchorCli $cli @{PublicKeyPemPath=$pemPath}).Output[0];$privateResult=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$privatePath} @($secretSpec);$privateResult.HadErrors|Should Be $false;$privateResult.ReadCount|Should Be 1;$private=$privateResult.Output[0];foreach($actual in @($xml,$pem,$private)){$actual.xmlSha256|Should Be $expected.xmlSha256;$actual.spkiSha256|Should Be $expected.spkiSha256};Assert-TestSentinelAbsentFromCliSurfaces $privateResult $passwordText}finally{$publicRsa.Dispose()}
    }

    # Scenario: Fingerprint inputs contain unencrypted PKCS#8, unencrypted PKCS#1, or private RSA XML generated at runtime.
    # Purpose: Reject private material at the byte boundary before any immutable managed string can be created.
    It 'InterT20_rejects_unencrypted_private_key_files_and_private_XML_at_the_byte_boundary' {
        $rsa=[Security.Cryptography.RSA]::Create(3072);$cli=Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1'
        try{
            $fixtures=@(@{Name='plain-pkcs8.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportPkcs8PrivateKeyPem()))},@{Name='plain-pkcs1.pem';Bytes=(ConvertTo-TestUtf8Bytes ($rsa.ExportRSAPrivateKeyPem()))})
            foreach($fixture in $fixtures){$path=Join-Path $TestDrive $fixture.Name;Write-TestPrivateKeyFixture $path $fixture.Bytes;$result=Invoke-TestTrustAnchorCli $cli @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec));$result.HadErrors|Should Be $true;$result.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat';[Security.Cryptography.CryptographicOperations]::ZeroMemory($fixture.Bytes)}
            $parameters=$rsa.ExportParameters($true);$xml='<RSAKeyValue><Modulus>'+[Convert]::ToBase64String($parameters.Modulus)+'</Modulus><Exponent>'+[Convert]::ToBase64String($parameters.Exponent)+'</Exponent><D>'+[Convert]::ToBase64String($parameters.D)+'</D></RSAKeyValue>';$xmlPath=Join-Path $TestDrive 'private.xml';[byte[]]$xmlBytes=ConvertTo-TestUtf8Bytes $xml;try{Write-TestPrivateKeyFixture $xmlPath $xmlBytes;$xmlResult=Invoke-TestTrustAnchorCli $cli @{PublicKeyXmlPath=$xmlPath};$xmlResult.HadErrors|Should Be $true;$xmlResult.Errors[0].Exception.InnerException.ErrorRecord.FullyQualifiedErrorId|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($xmlBytes)}
        }finally{$rsa.Dispose()}
    }
}

Describe 'PR-K1 trust-anchor path lease and rollback safety' {
    # Scenario: An output path is placed below this repository worktree.
    # Purpose: Prevent private keys and generated public output from entering Git history.
    It 'UnitT21_rejects_output_inside_a_worktree' {
        $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=(Join-Path $script:RepositoryRoot 'fixture-key.pem');PublicKeyXmlPath=(Join-Path $TestDrive 'fixture-public.xml')};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match 'outside every Git worktree'
    }

    # Scenario: A retained preflight parent is renamed and a Git worktree replaces its pathname before create-new.
    # Purpose: Bind physical/worktree preflight evidence to the exact parent lease used by creation.
    It 'InterT22_reuses_the_preflight_parent_lease_or_fails_closed' {
        $parent=Join-Path $TestDrive 'approved';$displaced=Join-Path $TestDrive 'approved-original';[void][IO.Directory]::CreateDirectory($parent);$signal=Join-Path $TestDrive 'parent-barrier.signal';$witnessPath=Join-Path $TestDrive 'parent-barrier.clixml';$job=Start-Job -ScriptBlock (Get-TestDirectoryMoveAdversaryScript) -ArgumentList $signal,$witnessPath,$parent,$displaced
        try{$secretSpec=New-TestSecretSpec;$private=Join-Path $parent 'key.pem';$public=Join-Path $TestDrive 'key.xml';$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;if($IsWindows){$witness.Succeeded|Should Be $false;$witness.Win32Error|Should Be 32;$witness.HResult|Should Be -2147467259;$result.HadErrors|Should Be $false;$result.ReadCount|Should Be 2;(Test-Path -LiteralPath $private)|Should Be $true;(Test-Path -LiteralPath $public)|Should Be $true}else{$witness.Succeeded|Should Be $true;$witness.OriginalExists|Should Be $true;$witness.ReplacementGit|Should Be $true;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 2;$result.ErrorIds[0]|Should Be 'TrustAnchor.ParentIdentityChanged';(Test-Path -LiteralPath $private)|Should Be $false;(Test-Path -LiteralPath (Join-Path $displaced 'key.pem'))|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false}}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
    }

    # Scenario: A target parent is reached through a native symlink or junction.
    # Purpose: Resolve every ancestor physically before accepting an output location.
    It 'InterT23_rejects_native_link_ancestor' {
        $physical=Join-Path $TestDrive 'physical';$alias=Join-Path $TestDrive 'alias';[void][IO.Directory]::CreateDirectory($physical);if($IsWindows){New-Item -ItemType Junction -Path $alias -Target $physical|Out-Null}else{New-Item -ItemType SymbolicLink -Path $alias -Target $physical|Out-Null};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=(Join-Path $alias 'key.pem');PublicKeyXmlPath=(Join-Path $TestDrive 'key.xml')};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match '(?i)reparse|link'
    }

    # Scenario: A valid private file is given a second hard link before it is opened.
    # Purpose: Refuse aliases that defeat exclusive key ownership.
    It 'InterT24_rejects_a_multiply_linked_private_key' {
        $bytes=ConvertTo-TestUtf8Bytes 'fixture';$path=Join-Path $TestDrive 'linked.pem';try{Write-TestPrivateKeyFixture $path $bytes;New-Item -ItemType HardLink -Path (Join-Path $TestDrive 'alias.pem') -Target $path|Out-Null;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match 'exactly one link'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
    }

    # Scenario: An existing tracked file inside this worktree is supplied as a private-key input.
    # Purpose: Exercise the existing-file open path and reject all private material inside any worktree.
    It 'InterT25_rejects_an_existing_private_key_path_inside_a_worktree' {
        $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$script:ModulePath};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match 'outside every Git worktree'
    }

    # Scenario: Public output fails after the private key is created by the same internal action used by the CLI.
    # Purpose: Prove CLI orchestration removes the unchanged private identity on public-write failure.
    It 'InterT26_CLI_orchestration_rolls_back_the_unchanged_private_identity' {
        $secretSpec=New-TestSecretSpec;$private=Join-Path $TestDrive 'rollback-collision.pem';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$private} @($secretSpec,$secretSpec)
        $result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match '(?i)exist|create';(Test-Path -LiteralPath $private)|Should Be $false
    }

    # Scenario: A caller preloads and persistently rewrites the module guard, password function, and script state before setting a CI marker.
    # Purpose: A qualified forced import must discard the poisoned module instance before the formal CLI evaluates its guard.
    It 'InterT27_rejects_a_poisoned_preloaded_module_under_a_CI_marker' {
        $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{PublicKeyXmlPath=(Join-Path $TestDrive 'missing.xml')} -CiMarker CI -PreloadTamper
        $result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.NonInteractive';$result.ReadCount|Should Be 0
    }

    # Scenario: File creation, permission readback, byte write, and retained-handle ACL operations are inspected as exact AST operations.
    # Purpose: Require permission dominance before one write and reject wrong-lease, pathname-ACL, and unreachable-decoy mutations.
    It 'UnitT28_orders_permission_readback_before_key_bytes' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;(Test-TrustAnchorFilePrimitiveSemantics $source)|Should Be $true
        $mutations=@(
            $source.Replace("        if(`$PathEvidence.Purpose -ceq 'PrivateKey'){","        `$file.WriteNewBytes(`$Bytes)`n        if(`$PathEvidence.Purpose -ceq 'PrivateKey'){"),
            $source.Replace('Assert-TrustAnchorPrivatePermissions $file|Out-Null','Assert-TrustAnchorPrivatePermissions $parent|Out-Null'),
            $source.Replace('        $file.WriteNewBytes($Bytes)',"        [SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect([IO.File]::OpenHandle(`$PathEvidence.Path))`n        `$file.WriteNewBytes(`$Bytes)"),
            $source.Replace('        $file.WriteNewBytes($Bytes)',"        'Set-PlatformPermissions Assert-TrustAnchorPrivatePermissions WriteNewBytes'|Out-Null`n        `$file.WriteNewBytes(`$Bytes)")
        )
        foreach($mutated in $mutations){(Test-TrustAnchorFilePrimitiveSemantics $mutated)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
    }


    # Scenario: The complete command/member operation inventory of every private-material input action is compared exactly.
    # Purpose: Permit only bounded byte readers and the approved clear/dispose operations without regex or API denylists.
    It 'UnitT29_private_input_paths_use_only_bounded_clearable_byte_buffers' {
        $tokens=$null;$errors=$null;$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPrivateInputOperationSemantics $ast)|Should Be $true
        foreach($mutated in @($source.Replace('$bytes=$Lease.FileLease.ReadAllBytes(1048576)','$bytes=[IO.File]::ReadAllText($Lease.PathEvidence.Path)'),$source.Replace('$inputBytes=Read-TrustAnchorInputBytes $PublicKeyPemPath','$inputBytes=Get-Content -Raw $PublicKeyPemPath'),$source.Replace('$rsa=Import-TrustAnchorEncryptedPrivateKey -Bytes $inputBytes -Password $password','$text=[Text.Encoding]::UTF8.GetString($inputBytes);$rsa=Import-TrustAnchorEncryptedPrivateKey -Bytes $inputBytes -Password $password'))){$mutationTokens=$null;$mutationErrors=$null;$mutationAst=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$mutationTokens,[ref]$mutationErrors);@($mutationErrors).Count|Should Be 0;(Test-TrustAnchorPrivateInputOperationSemantics $mutationAst)|Should Be $false}
    }

    # Scenario: A formally permissioned private fixture contains a unique sentinel and fails after the production CLI reads it.
    # Purpose: Keep private bytes out of child environment, stdout, stderr, Error stream, transcript, result, and output files while cleanup mutations bind every clear point.
    It 'InterT30_clears_private_bytes_when_post_read_validation_throws' {
        $sentinel='private-buffer-sentinel-7f2d1c9a';[byte[]]$bytes=ConvertTo-TestUtf8Bytes $sentinel;$path=Join-Path $TestDrive 'post-read-clear.pem'
        try{Write-TestPrivateKeyFixture $path $bytes;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec));$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat';Assert-TestSentinelAbsentFromCliSurfaces $result $sentinel}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
    }

    # Scenario: Both parent-identity revalidation statements are removed by AST extent from a worktree-external production copy.
    # Purpose: Require the PowerShell semantic validator and the complete production golden to reject the same deletion mutant on every host.
    It 'InterT74_parent_identity_revalidation_deletion_mutant_fails_semantic_and_golden_contracts' {
        $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$function=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-TrustAnchorKeyFile'},$true))[0];$outerTry=@($function.Body.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]})[0];$identityNodes=@($outerTry.Body.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]});$identityNodes.Count|Should Be 2;$mutant=Remove-TestAstExtents $source $identityNodes;(Test-TrustAnchorFilePrimitiveSemantics $mutant)|Should Be $false;(Test-TrustAnchorProtectedContract 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1' $mutant)|Should Be $false
    }
}

if($IsWindows){
    Describe 'PR-K1 Windows native handle safety' {
        # Scenario: A broad-DACL original is open when an external adversary replaces its DACL with owner-only protection at the password barrier.
        # Purpose: Detect post-open DACL drift from retained-handle evidence before private bytes are parsed.
        It 'InterT31_share_lock_explicitly_prevents_pathname_replacement' {
            $path=Join-Path $TestDrive 'windows-broad.pem';[IO.File]::WriteAllText($path,'original');$signal=Join-Path $TestDrive 'windows-restrict.signal';$witnessPath=Join-Path $TestDrive 'windows-restrict.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false);$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $path -AclObject $security;$readback=Get-Acl -LiteralPath $path;[pscustomobject]@{Succeeded=$readback.AreAccessRulesProtected;RuleCount=@($readback.Access).Count}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}finally{$identity.Dispose()}} -ArgumentList $signal,$witnessPath,$path
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.RuleCount|Should Be 1;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 1;$result.ErrorIds[0]|Should Be 'TrustAnchor.PrivateMetadataChanged';$result.ErrorMessages[0]|Should Be 'The private-key handle metadata changed after it was opened.';(Test-Path -LiteralPath $path)|Should Be $true;[IO.File]::ReadAllText($path)|Should Be 'original'}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: A restrictive original is retained while an external adversary adds a world-readable allow ACE after open.
        # Purpose: Re-read DACL from the retained handle and reject the precise post-open permission mutation.
        It 'InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence' {
            $bytes=ConvertTo-TestUtf8Bytes 'malformed';$path=Join-Path $TestDrive 'windows-safe.pem';$signal=Join-Path $TestDrive 'windows-broad.signal';$witnessPath=Join-Path $TestDrive 'windows-broad.witness';$job=$null
            try{Write-TestPrivateKeyFixture $path $bytes;$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false);$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path),$security);$readback=Get-Acl -LiteralPath $path;[pscustomobject]@{Succeeded=$readback.AreAccessRulesProtected;RuleCount=@($readback.Access).Count}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}finally{$identity.Dispose()}} -ArgumentList $signal,$witnessPath,$path;$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.RuleCount|Should Be 2;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 1;$result.ErrorIds[0]|Should Be 'TrustAnchor.UnsafePrivatePermissions';$result.ErrorMessages[0]|Should Be 'The private-key handle owner or protected DACL is not sufficiently restrictive.';(Test-Path -LiteralPath $path)|Should Be $true}finally{if($null-ne$job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue};[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
        }

        # Scenario: The private-key leaf is a file symlink, with a directory-junction fallback when symlink creation is unavailable.
        # Purpose: Reject every Windows leaf reparse point and explicitly prove the fixture carries ReparsePoint.
        It 'InterT33_rejects_a_private_key_leaf_reparse_point' {
            $target=Join-Path $TestDrive 'reparse-target.pem';$leaf=Join-Path $TestDrive 'reparse-leaf.pem';[IO.File]::WriteAllText($target,'fixture');try{New-Item -ItemType SymbolicLink -Path $leaf -Target $target -ErrorAction Stop|Out-Null}catch{$targetDirectory=Join-Path $TestDrive 'reparse-target-dir';[void][IO.Directory]::CreateDirectory($targetDirectory);$leaf=Join-Path $TestDrive 'reparse-leaf-dir';New-Item -ItemType Junction -Path $leaf -Target $targetDirectory -ErrorAction Stop|Out-Null};(([IO.File]::GetAttributes($leaf)-band[IO.FileAttributes]::ReparsePoint)-ne0)|Should Be $true;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$leaf};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match '(?i)reparse'
        }

        # Scenario: The formal key-pair action creates a private file and returns before native ACL readback.
        # Purpose: Independently verify the resulting DACL is protected and grants allow access only to approved SIDs.
        It 'InterT34_formal_creation_has_an_independently_verified_restrictive_DACL' {
            $secretSpec=New-TestSecretSpec;$private=Join-Path $TestDrive 'acl-private.pem';$public=Join-Path $TestDrive 'acl-public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $false;$acl=Get-Acl -LiteralPath $private;$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$owner|Should Be $identity.User.Value;$acl.AreAccessRulesProtected|Should Be $true;$rules=@($acl.Access);$rules.Count|Should Be 1;$rule=$rules[0];$rule.IsInherited|Should Be $false;$rule.AccessControlType|Should Be ([Security.AccessControl.AccessControlType]::Allow);$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value|Should Be $identity.User.Value;(($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::Read)-eq[Security.AccessControl.FileSystemRights]::Read)|Should Be $true;(($rule.FileSystemRights-band[Security.AccessControl.FileSystemRights]::Write)-eq[Security.AccessControl.FileSystemRights]::Write)|Should Be $true}finally{$identity.Dispose()}
        }

        # Scenario: The official shard supervisor starts a minimal Pester file with closed stdin, NonInteractive, and CREATE_NO_WINDOW.
        # Purpose: Prove the same ConPTY driver gives the formal CLI a real console stdin even through the production shard transport.
        It 'InterT35_ConPTY_survives_the_official_closed_stdin_shard_transport' {
            $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath());$root=Join-Path $tempRoot ('p11-k1-conpty-'+[Guid]::NewGuid().ToString('N'));if(([IO.Path]::GetDirectoryName($root).TrimEnd([IO.Path]::DirectorySeparatorChar))-cne$tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)-or[IO.Path]::GetFileName($root)-cnotmatch'^p11-k1-conpty-[0-9a-f]{32}$'){throw 'ConPTY probe temporary root validation failed.'};try{$testRoot=Join-Path $root 'tests';$evidenceRoot=Join-Path $root 'evidence';[void][IO.Directory]::CreateDirectory($testRoot);[void][IO.Directory]::CreateDirectory($evidenceRoot)
            $driver=Join-Path $root 'driver.ps1';$hostSource=Join-Path $root 'host.cs';$conPtySource=Join-Path $root 'conpty.cs';$configPath=Join-Path $root 'config.clixml';$resultPath=Join-Path $root 'result.clixml';$transcriptPath=Join-Path $root 'transcript.txt';$statePath=Join-Path $root 'state.clixml';$supervisor=Join-Path $root 'supervisor.ps1';$probeTest=Join-Path $testRoot 'conpty-shard-probe.Tests.ps1';$summaryPath=Join-Path $evidenceRoot 'summary.json';$publicFixture=Join-Path $root 'public.pem';$probeRsa=[Security.Cryptography.RSA]::Create(3072)
            try{$expectedXml=ConvertTo-TestCanonicalXmlBytes $probeRsa;$expectedXmlSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedXml)).ToLowerInvariant();$expectedSpkiSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($probeRsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant();[IO.File]::WriteAllText($publicFixture,$probeRsa.ExportSubjectPublicKeyInfoPem(),[Text.UTF8Encoding]::new($false))}finally{$probeRsa.Dispose()}
            [IO.File]::WriteAllText($driver,(Get-TestCliDriverSource),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($hostSource,$script:TrustAnchorTestHostSource,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($conPtySource,$script:TrustAnchorConPtySource,[Text.UTF8Encoding]::new($false));[pscustomobject]@{Path=(Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1');Parameters=@{PublicKeyPemPath=$publicFixture};ResponseSpecs=@();ModulePath=$script:ModulePath;PreloadTamper=$false;PreloadPathTamper=$false;BarrierSpecs=@();CiMarker='';UseConPty=$true;HostSourcePath=$hostSource;ResultPath=$resultPath;TranscriptPath=$transcriptPath}|Export-Clixml -LiteralPath $configPath -Depth 8
            $literal={param([string]$value)"'"+$value.Replace("'","''")+"'"};$testSource=@"
Describe 'official shard ConPTY probe' {
    # Scenario: The production fingerprint CLI is started by the shared ConPTY driver from an official shard child.
    # Purpose: Require console stdin, no driver failure, and the exact action-specific fingerprint from the formal CLI.
    It 'InterT01_runs_the_formal_CLI_with_console_stdin' {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($(& $literal $conPtySource)))
        try {
            `$pwsh=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            `$launch=[SyuanTsai.AIInstructions.TrustAnchor.Tests.ConPtyLauncher]::Run(`$pwsh,@('-NoProfile','-File',$(& $literal $driver),'-ConfigPath',$(& $literal $configPath)),$(& $literal $script:RepositoryRoot),180000)
            `$launch.ExitCode|Should Be 0
            `$result=Import-Clixml -LiteralPath $(& $literal $resultPath)
            `$result.InteractiveState.InputRedirected|Should Be `$false
            `$result.InteractiveState.UserInteractive|Should Be `$true
            (`$null-eq`$result.PSObject.Properties['DriverFailure']-or-not[bool]`$result.DriverFailure)|Should Be `$true
            `$result.HadErrors|Should Be `$false
            @(`$result.Output).Count|Should Be 1
            `$result.Output[0].xmlSha256|Should Be '$expectedXmlSha'
            `$result.Output[0].spkiSha256|Should Be '$expectedSpkiSha'
            `$result.InteractiveState|Export-Clixml -LiteralPath $(& $literal $statePath)
        } finally { foreach(`$artifact in @($(& $literal $driver),$(& $literal $hostSource),$(& $literal $configPath),$(& $literal $resultPath),$(& $literal $transcriptPath))){Remove-Item -LiteralPath `$artifact -Force -ErrorAction SilentlyContinue} }
    }
}
"@
            [IO.File]::WriteAllText($probeTest,$testSource,[Text.UTF8Encoding]::new($false));$pesterSource=(Get-Module Pester -ErrorAction Stop).ModuleBase;$pesterRoot=Join-Path $root 'pester';[void][IO.Directory]::CreateDirectory($pesterRoot);Get-ChildItem -LiteralPath $pesterSource -Force|Copy-Item -Destination $pesterRoot -Recurse -Force;$pesterModule=Join-Path $pesterRoot 'Pester.psd1';$supervisorSource=@'
param([string]$FormalScript,[string]$PesterModulePath,[string]$TestRoot,[string]$EvidenceRoot,[string]$SummaryOutputPath)
try { & $FormalScript -PesterModulePath $PesterModulePath -PesterVersion '4.10.1' -ExpectedTotalCount 1 -ExpectedSkippedCount 0 -IsolatedTestFileNames ([string[]]@()) -BulkShardSize 1 -OuterTimeoutSeconds 300 -TestRoot $TestRoot -EvidenceRoot $EvidenceRoot -SelectedTestFileNames 'conpty-shard-probe.Tests.ps1' -SummaryOutputPath $SummaryOutputPath; exit 0 } catch { [Console]::Error.WriteLine([string]$_); exit 1 }
'@;[IO.File]::WriteAllText($supervisor,$supervisorSource,[Text.UTF8Encoding]::new($false));$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$info.WorkingDirectory=$script:RepositoryRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            foreach($value in @('-NoProfile','-NonInteractive','-File',$supervisor,'-FormalScript',(Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'),'-PesterModulePath',$pesterModule,'-TestRoot',$testRoot,'-EvidenceRoot',$evidenceRoot,'-SummaryOutputPath',$summaryPath)){$info.ArgumentList.Add([string]$value)}
            $process=[Diagnostics.Process]::Start($info);$process.StandardInput.Close();$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit();try{$stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult();if($process.ExitCode-ne0){$details=@(Get-ChildItem -LiteralPath $evidenceRoot -File|Sort-Object Name|ForEach-Object{"$($_.Name): $([IO.File]::ReadAllText($_.FullName))"})-join"`n";throw "Official shard ConPTY probe failed (exit=$($process.ExitCode)). stdout=$stdout stderr=$stderr evidence=$details"};$stderr|Should Be '';(Test-Path -LiteralPath $summaryPath)|Should Be $true;$summary=Get-Content -Raw -LiteralPath $summaryPath|ConvertFrom-Json;$summary.counts.PassedCount|Should Be 1;$summary.counts.FailedCount|Should Be 0;$state=Import-Clixml -LiteralPath $statePath;Write-Host "ConPTY shard transport state: IsInputRedirected=$($state.InputRedirected); UserInteractive=$($state.UserInteractive)";$state.InputRedirected|Should Be $false;$state.UserInteractive|Should Be $true}finally{$process.Dispose()}}finally{if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$true)}}
        }

        # Scenario: Post-open metadata comparison and retained-handle permission validation are deleted separately from external production copies.
        # Purpose: Re-run the InterT31 and InterT32 DACL barriers and require each mutant to lose the corresponding exact failure contract.
        It 'InterT75_Windows_post_open_revalidation_deletion_mutants_fail_their_barrier_contracts' {
            $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$read=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Read-TrustAnchorPrivateKeyLease'},$true))[0];$metadataIf=@($read.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and@($node.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Test-TrustAnchorMetadataEqual'},$true)).Count-gt0},$true)|Sort-Object{$_.Extent.StartOffset})[0];$permissionTries=@($read.FindAll({param($node)$node-is[Management.Automation.Language.TryStatementAst]-and@($node.Body.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Assert-TrustAnchorPrivatePermissions'},$true)).Count-eq1},$true)|Sort-Object{$_.Extent.StartOffset});$permissionTries.Count|Should Be 2;$metadataMutant=Remove-TestAstExtents $source @($metadataIf);$permissionMutant=Remove-TestAstExtents $source $permissionTries;foreach($mutant in @($metadataMutant,$permissionMutant)){$mutationTokens=$null;$mutationErrors=$null;$mutationAst=[Management.Automation.Language.Parser]::ParseInput($mutant,[ref]$mutationTokens,[ref]$mutationErrors);@($mutationErrors).Count|Should Be 0;(Test-TrustAnchorPrivateInputOperationSemantics $mutationAst)|Should Be $false;(Test-TrustAnchorProtectedContract 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1' $mutant)|Should Be $false};$metadataRoot=New-TestMutantTrustAnchorCliRoot 'windows-metadata' $metadataMutant;$permissionRoot=New-TestMutantTrustAnchorCliRoot 'windows-permission' $permissionMutant
            $path=Join-Path $TestDrive 'mutant-windows-metadata.pem';[IO.File]::WriteAllText($path,'original');$signal=Join-Path $TestDrive 'mutant-windows-metadata.signal';$witnessPath=Join-Path $TestDrive 'mutant-windows-metadata.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false);$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $path -AclObject $security;[pscustomobject]@{Succeeded=$true}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}finally{$identity.Dispose()}} -ArgumentList $signal,$witnessPath,$path
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $metadataRoot 'Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;(Import-Clixml -LiteralPath $witnessPath).Succeeded|Should Be $true;($result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.PrivateMetadataChanged')|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
            $bytes=ConvertTo-TestUtf8Bytes 'malformed';$path=Join-Path $TestDrive 'mutant-windows-permission.pem';$signal=Join-Path $TestDrive 'mutant-windows-permission.signal';$witnessPath=Join-Path $TestDrive 'mutant-windows-permission.witness';$job=$null
            try{Write-TestPrivateKeyFixture $path $bytes;$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};$identity=[Security.Principal.WindowsIdentity]::GetCurrent();try{$security=[Security.AccessControl.FileSecurity]::new();$security.SetOwner($identity.User);$security.SetAccessRuleProtection($true,$false);$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow));[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path),$security);[pscustomobject]@{Succeeded=$true}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}finally{$identity.Dispose()}} -ArgumentList $signal,$witnessPath,$path;$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $permissionRoot 'Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;(Import-Clixml -LiteralPath $witnessPath).Succeeded|Should Be $true;($result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.UnsafePrivatePermissions')|Should Be $false}finally{if($null-ne$job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue};[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
        }

        # Scenario: The Windows directory guard share mode is mutated by Roslyn extent to permit delete/rename during the InterT22 password barrier.
        # Purpose: Prove the OS lease denial, Roslyn semantic contract, and complete C# golden all fail when FILE_SHARE_DELETE is introduced.
        It 'InterT78_Windows_directory_share_mutant_allows_rename_and_fails_the_lease_contract' {
            $relative='scripts/platform/WindowsInstallerMutation.cs';$nativeRelative='scripts/platform/WindowsNative.cs';$source=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot $relative);$nativeSource=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot $nativeRelative);(Test-TrustAnchorWindowsDirectoryLeaseSemantics $source $nativeSource)|Should Be $true;(Test-TrustAnchorProtectedContract $relative $source)|Should Be $true;(Test-TrustAnchorProtectedContract $nativeRelative $nativeSource)|Should Be $true
            $analysis=Get-TrustAnchorCSharpAnalysis $source;$method=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'OpenValidatedDirectory'})[0];$call=@($method.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'CreateFile'})[0];$share=$call.ArgumentList.Arguments[2].Expression;$mutant=Set-TestSourceSpan $source $share.SpanStart $share.Span.Length 'FileShareRead | FileShareWrite | FileShareDelete';(Test-TrustAnchorWindowsDirectoryLeaseSemantics $mutant $nativeSource)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutant)|Should Be $false
            $nativeTree=[Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($nativeSource);$wrap=@($nativeTree.GetRoot().DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'WrapDirectory'})[0];$open=@($wrap.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'Open'})[0];$nativeShare=$open.ArgumentList.Arguments[2].Expression;$nativeMutant=Set-TestSourceSpan $nativeSource $nativeShare.SpanStart $nativeShare.Span.Length '7';(Test-TrustAnchorWindowsDirectoryLeaseSemantics $source $nativeMutant)|Should Be $false;(Test-TrustAnchorProtectedContract $nativeRelative $nativeMutant)|Should Be $false;$moduleSource=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$cliRoot=New-TestMutantTrustAnchorCliRoot 'windows-share-delete' $moduleSource $mutant $nativeMutant
            $parent=Join-Path $TestDrive 'share-mutant-approved';$displaced=Join-Path $TestDrive 'share-mutant-original';[void][IO.Directory]::CreateDirectory($parent);$signal=Join-Path $TestDrive 'share-mutant.signal';$witnessPath=Join-Path $TestDrive 'share-mutant.witness';$job=Start-Job -ScriptBlock (Get-TestDirectoryMoveAdversaryScript) -ArgumentList $signal,$witnessPath,$parent,$displaced
            try{$secretSpec=New-TestSecretSpec -Seed 780;$private=Join-Path $parent 'key.pem';$public=Join-Path $TestDrive 'share-mutant.xml';$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $cliRoot 'New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.OriginalExists|Should Be $true;$witness.ReplacementGit|Should Be $true;$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Be 'TrustAnchor.ParentIdentityChanged';(Test-Path -LiteralPath $private)|Should Be $false;(Test-Path -LiteralPath (Join-Path $displaced 'key.pem'))|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false;$originalLeaseContract=(-not$witness.Succeeded)-and$witness.Win32Error-eq32-and-not$result.HadErrors-and(Test-Path -LiteralPath $private)-and(Test-Path -LiteralPath $public);$originalLeaseContract|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }
    }
}else{
    Describe 'PR-K1 Unix native handle safety' {
        # Scenario: An owner-only 0400 private file is opened.
        # Purpose: Accept every owner-only mode rather than requiring mode exactly 0600.
        It 'InterT40_accepts_owner_only_mode_0400' {
            $secretSpec=New-TestSecretSpec;$path=Join-Path $TestDrive 'readonly.pem';$public=Join-Path $TestDrive 'readonly.xml';(Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$path;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec)).HadErrors|Should Be $false;chmod 400 $path;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @($secretSpec);$result.HadErrors|Should Be $false
        }

        # Scenario: A broad-mode original is opened, then an external adversary replaces its pathname with a 0600 file at the password barrier.
        # Purpose: Permission validation must remain bound to the original open handle.
        It 'InterT41_rejects_the_original_broad_mode_after_pathname_replacement' {
            $path=Join-Path $TestDrive 'unix-broad.pem';$replacement=Join-Path $TestDrive 'unix-restrictive.pem';$displaced=Join-Path $TestDrive 'unix-broad-original.pem';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 640 $path;chmod 600 $replacement;$signal=Join-Path $TestDrive 'unix-broad.signal';$witnessPath=Join-Path $TestDrive 'unix-broad.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path,$replacement,$displaced)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{[IO.File]::Move($path,$displaced);[IO.File]::Move($replacement,$path);[pscustomobject]@{Succeeded=$true;Original=[IO.File]::Exists($displaced);Replacement=[IO.File]::Exists($path)}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path,$replacement,$displaced
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.Original|Should Be $true;$witness.Replacement|Should Be $true;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 1;$result.ErrorIds[0]|Should Be 'TrustAnchor.UnsafePrivatePermissions';$result.ErrorMessages[0]|Should Be 'The private-key handle must be owned by the effective user and deny every group/other permission.';[IO.File]::ReadAllText($displaced)|Should Be 'original';[IO.File]::ReadAllText($path)|Should Be 'replacement'}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: The external adversary changes mode on the retained inode after open and before the read/revalidation phase.
        # Purpose: Detect the post-open metadata drift at the host-input synchronization barrier with an exact reason.
        It 'InterT42_rejects_metadata_change_during_read' {
            $path=Join-Path $TestDrive 'metadata.pem';[IO.File]::WriteAllText($path,('x'*1048576));chmod 600 $path;$signal=Join-Path $TestDrive 'metadata.signal';$witnessPath=Join-Path $TestDrive 'metadata.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{chmod 400 $path;[pscustomobject]@{Succeeded=$LASTEXITCODE-eq0;Mode=[int][IO.File]::GetUnixFileMode($path)}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;($witness.Mode-band511)|Should Be 256;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 1;$result.ErrorIds[0]|Should Be 'TrustAnchor.PrivateMetadataChanged';$result.ErrorMessages[0]|Should Be 'The private-key handle metadata changed after it was opened.';(Test-Path -LiteralPath $path)|Should Be $true}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: The private-key leaf itself is a native symbolic link.
        # Purpose: Require no-follow semantics for the final private-key component.
        It 'InterT43_rejects_a_private_key_leaf_symbolic_link' {
            $target=Join-Path $TestDrive 'leaf-target.pem';$leaf=Join-Path $TestDrive 'leaf-link.pem';[IO.File]::WriteAllText($target,'fixture');chmod 600 $target;New-Item -ItemType SymbolicLink -Path $leaf -Target $target|Out-Null;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$leaf};$result.HadErrors|Should Be $true
        }

        # Scenario: The formal key-pair action creates a private file before independent native mode readback.
        # Purpose: Verify the persisted file is regular, owner-only, and not merely accepted by the module's own check.
        It 'InterT44_formal_creation_has_an_independently_verified_owner_only_mode' {
            $secretSpec=New-TestSecretSpec;$private=Join-Path $TestDrive 'mode-private.pem';$public=Join-Path $TestDrive 'mode-public.xml';(Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec)).HadErrors|Should Be $false;$mode=[IO.File]::GetUnixFileMode($private);([int]$mode-band511)|Should Be 384;$handle=[IO.File]::OpenHandle($private,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);try{$evidence=[SyuanTsai.AIInstructions.TrustAnchor.UnixMetadataInspector]::Inspect($handle);([uint32]$evidence.Mode-band0xF000)|Should Be 0x8000;[uint64]$evidence.Uid|Should Be ([SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::EffectiveUid())}finally{$handle.Dispose()}
        }

        # Scenario: Both original and replacement are mode 0600 regular files, and the external adversary changes pathname identity after open.
        # Purpose: Reach the final identity revalidation independently of permission rejection.
        It 'InterT45_rejects_post_read_identity_replacement_when_both_files_are_restrictive' {
            $path=Join-Path $TestDrive 'identity-original.pem';$replacement=Join-Path $TestDrive 'identity-safe.pem';$displaced=Join-Path $TestDrive 'identity-retained.pem';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 600 $path;chmod 600 $replacement;$signal=Join-Path $TestDrive 'identity.signal';$witnessPath=Join-Path $TestDrive 'identity.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path,$replacement,$displaced)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{[IO.File]::Move($path,$displaced);[IO.File]::Move($replacement,$path);[pscustomobject]@{Succeeded=$true;Original=[IO.File]::Exists($displaced);Replacement=[IO.File]::Exists($path)}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path,$replacement,$displaced
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.Original|Should Be $true;$witness.Replacement|Should Be $true;$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 1;$result.ErrorIds[0]|Should Be 'TrustAnchor.PrivateIdentityChanged';[IO.File]::ReadAllText($displaced)|Should Be 'original';[IO.File]::ReadAllText($path)|Should Be 'replacement'}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: The Unix permission, metadata, and identity revalidations are each deleted from worktree-external production copies.
        # Purpose: Re-run the InterT41, InterT42, and InterT45 barriers and require each mutant to lose the corresponding exact failure contract.
        It 'InterT76_Unix_post_open_revalidation_deletion_mutants_fail_their_barrier_contracts' {
            $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$read=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Read-TrustAnchorPrivateKeyLease'},$true))[0];$metadataIf=@($read.FindAll({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and@($node.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Test-TrustAnchorMetadataEqual'},$true)).Count-gt0},$true)|Sort-Object{$_.Extent.StartOffset})[0];$permissionTries=@($read.FindAll({param($node)$node-is[Management.Automation.Language.TryStatementAst]-and@($node.Body.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Assert-TrustAnchorPrivatePermissions'},$true)).Count-eq1},$true)|Sort-Object{$_.Extent.StartOffset});$identityTry=@($read.FindAll({param($node)$node-is[Management.Automation.Language.TryStatementAst]-and@($node.Body.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Assert-PlatformFileIdentity'},$true)).Count-eq1},$true))[0];$permissionTries.Count|Should Be 2;$permissionMutant=Remove-TestAstExtents $source $permissionTries;$metadataMutant=Remove-TestAstExtents $source @($metadataIf);$identityMutant=Remove-TestAstExtents $source @($identityTry);foreach($mutant in @($permissionMutant,$metadataMutant,$identityMutant)){$mutationTokens=$null;$mutationErrors=$null;$mutationAst=[Management.Automation.Language.Parser]::ParseInput($mutant,[ref]$mutationTokens,[ref]$mutationErrors);@($mutationErrors).Count|Should Be 0;(Test-TrustAnchorPrivateInputOperationSemantics $mutationAst)|Should Be $false;(Test-TrustAnchorProtectedContract 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1' $mutant)|Should Be $false};$permissionRoot=New-TestMutantTrustAnchorCliRoot 'unix-permission' $permissionMutant;$metadataRoot=New-TestMutantTrustAnchorCliRoot 'unix-metadata' $metadataMutant;$identityRoot=New-TestMutantTrustAnchorCliRoot 'unix-identity' $identityMutant
            $path=Join-Path $TestDrive 'mutant-unix-permission.pem';$replacement=Join-Path $TestDrive 'mutant-unix-permission-replacement.pem';$displaced=Join-Path $TestDrive 'mutant-unix-permission-original.pem';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 640 $path;chmod 600 $replacement;$signal=Join-Path $TestDrive 'mutant-unix-permission.signal';$witnessPath=Join-Path $TestDrive 'mutant-unix-permission.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path,$replacement,$displaced)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{[IO.File]::Move($path,$displaced);[IO.File]::Move($replacement,$path);[pscustomobject]@{Succeeded=$true}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path,$replacement,$displaced
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $permissionRoot 'Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;(Import-Clixml -LiteralPath $witnessPath).Succeeded|Should Be $true;($result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.UnsafePrivatePermissions')|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
            $path=Join-Path $TestDrive 'mutant-unix-metadata.pem';[IO.File]::WriteAllText($path,('x'*1048576));chmod 600 $path;$signal=Join-Path $TestDrive 'mutant-unix-metadata.signal';$witnessPath=Join-Path $TestDrive 'mutant-unix-metadata.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{chmod 400 $path;[pscustomobject]@{Succeeded=$LASTEXITCODE-eq0}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $metadataRoot 'Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;(Import-Clixml -LiteralPath $witnessPath).Succeeded|Should Be $true;($result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.PrivateMetadataChanged')|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
            $path=Join-Path $TestDrive 'mutant-unix-identity.pem';$replacement=Join-Path $TestDrive 'mutant-unix-identity-replacement.pem';$displaced=Join-Path $TestDrive 'mutant-unix-identity-original.pem';[IO.File]::WriteAllText($path,'original');[IO.File]::WriteAllText($replacement,'replacement');chmod 600 $path;chmod 600 $replacement;$signal=Join-Path $TestDrive 'mutant-unix-identity.signal';$witnessPath=Join-Path $TestDrive 'mutant-unix-identity.witness';$job=Start-Job -ScriptBlock {param($signal,$witness,$path,$replacement,$displaced)while(-not[IO.File]::Exists($signal)){[Threading.Thread]::Sleep(10)};try{[IO.File]::Move($path,$displaced);[IO.File]::Move($replacement,$path);[pscustomobject]@{Succeeded=$true}|Export-Clixml -LiteralPath $witness}catch{[pscustomobject]@{Succeeded=$false;Error=$_.Exception.Message}|Export-Clixml -LiteralPath $witness}} -ArgumentList $signal,$witnessPath,$path,$replacement,$displaced
            try{$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $identityRoot 'Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$path} @((New-TestSecretSpec)) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;(Import-Clixml -LiteralPath $witnessPath).Succeeded|Should Be $true;($result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.PrivateIdentityChanged')|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: The two parent-identity revalidations are removed and the Unix adversary successfully replaces the retained parent pathname at the password barrier.
        # Purpose: Execute the parent deletion mutant only on a native host where rename succeeds and prove the protected ParentIdentityChanged outcome is lost.
        It 'InterT77_Unix_parent_identity_revalidation_deletion_mutant_fails_the_barrier_contract' {
            $source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$function=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-TrustAnchorKeyFile'},$true))[0];$outerTry=@($function.Body.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]})[0];$identityNodes=@($outerTry.Body.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]});$identityNodes.Count|Should Be 2;$mutant=Remove-TestAstExtents $source $identityNodes;(Test-TrustAnchorFilePrimitiveSemantics $mutant)|Should Be $false;(Test-TrustAnchorProtectedContract 'scripts/trust-anchor/TrustAnchorPrivateKey.psm1' $mutant)|Should Be $false;$cliRoot=New-TestMutantTrustAnchorCliRoot 'unix-parent-identity' $mutant
            $parent=Join-Path $TestDrive 'unix-mutant-approved';$displaced=Join-Path $TestDrive 'unix-mutant-original';[void][IO.Directory]::CreateDirectory($parent);$signal=Join-Path $TestDrive 'unix-mutant-parent.signal';$witnessPath=Join-Path $TestDrive 'unix-mutant-parent.witness';$job=Start-Job -ScriptBlock (Get-TestDirectoryMoveAdversaryScript) -ArgumentList $signal,$witnessPath,$parent,$displaced
            try{$secretSpec=New-TestSecretSpec -Seed 770;$private=Join-Path $parent 'key.pem';$public=Join-Path $TestDrive 'unix-mutant-key.xml';$barrier=[pscustomobject]@{ReadCount=1;SignalPath=$signal;WitnessPath=$witnessPath;TimeoutMilliseconds=30000};$result=Invoke-TestTrustAnchorCli (Join-Path $cliRoot 'New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec) -BarrierSpecs @($barrier);Wait-Job $job|Out-Null;$witness=Import-Clixml -LiteralPath $witnessPath;$witness.Succeeded|Should Be $true;$witness.OriginalExists|Should Be $true;$witness.ReplacementGit|Should Be $true;$protected=$result.HadErrors-and$result.ErrorIds[0]-ceq'TrustAnchor.ParentIdentityChanged'-and-not(Test-Path -LiteralPath (Join-Path $displaced 'key.pem'));$protected|Should Be $false}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
        }

        # Scenario: After rename validation, the private tombstone is displaced and an unrelated replacement occupies its name.
        # Purpose: Revalidate inside the retained 0700 rollback directory and preserve both entries on uncertainty.
        It 'InterT46_rollback_fails_closed_when_the_tombstone_is_replaced_before_unlink' {
            $secretSpec=New-TestSecretSpec;$private=Join-Path $TestDrive 'tombstone-private.pem';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='supervisor';PrivateKeyPath=$private;PublicKeyXmlPath=$private} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $true;(Test-Path -LiteralPath $private)|Should Be $false
        }

        # Scenario: A hard link to the tombstone is created after rename and before unlink.
        # Purpose: Require single-link evidence immediately before unlink and retain the key when another link exists.
        It 'InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink' {
            $bytes=ConvertTo-TestUtf8Bytes 'fixture';$private=Join-Path $TestDrive 'hardlink-private.pem';try{Write-TestPrivateKeyFixture $private $bytes;New-Item -ItemType HardLink -Path (Join-Path $TestDrive 'hardlink-private.link') -Target $private|Out-Null;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$private};$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match 'exactly one link'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
        }

        # Scenario: A private output parent is group-writable without sticky protection, or world-writable with sticky protection.
        # Purpose: Reject cross-UID entry replacement before file creation while accepting the standard sticky-directory boundary.
        It 'InterT48_enforces_the_rollback_parent_boundary_for_<Mode>' -TestCases @(
            @{Mode='0770';Accept=$false},
            @{Mode='1777';Accept=$true}
        ) {
            param($Mode,$Accept)
            $parent=Join-Path $TestDrive "rollback-parent-$Mode";[void][IO.Directory]::CreateDirectory($parent);chmod $Mode $parent
            $secretSpec=New-TestSecretSpec;$path=Join-Path $parent 'private.pem';$public=Join-Path $parent 'public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$path;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec)
            if($Accept){$result.HadErrors|Should Be $false;(Test-Path -LiteralPath $path)|Should Be $true}else{$result.HadErrors|Should Be $true;$result.ErrorMessages[0]|Should Match 'owner-only or sticky';(Test-Path -LiteralPath $path)|Should Be $false;@(Get-ChildItem -Force -LiteralPath $parent).Count|Should Be 0}
        }

        if($IsLinux){
            # Scenario: A Linux 0700 parent receives a named-user writable POSIX ACL through setfacl.
            # Purpose: Prove the ACL mask is reflected in group class mode bits and the retained-handle mode check rejects it.
            It 'InterT68_rejects_a_Linux_named_user_writable_parent_ACL' {
                $setfacl=Get-Command setfacl -CommandType Application -ErrorAction Stop;$parent=Join-Path $TestDrive 'linux-acl-parent';[void][IO.Directory]::CreateDirectory($parent);chmod 700 $parent;& $setfacl.Source -m 'u:nobody:rwx' $parent;if($LASTEXITCODE-ne0){throw 'setfacl failed to create the required Linux ACL fixture.'}
                $secretSpec=New-TestSecretSpec;$path=Join-Path $parent 'private.pem';$public=Join-Path $parent 'public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$path;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 2;$result.ErrorIds[0]|Should Be 'TrustAnchor.UnsafeParentAcl';$result.ErrorMessages[0]|Should Be 'The private trust-anchor parent must be owner-only or sticky and owned by the effective user or root.';(Test-Path -LiteralPath $path)|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false
            }
        }
        if($IsMacOS){
            # Scenario: A macOS 0700 parent receives an extended ACL granting nobody add_file and delete_child.
            # Purpose: Reject extended ACLs through acl_get_fd_np on the retained directory descriptor before any entry is created.
            It 'InterT69_rejects_a_macOS_extended_parent_ACL' {
                $parent=Join-Path $TestDrive 'macos-acl-parent';[void][IO.Directory]::CreateDirectory($parent);chmod 700 $parent;chmod +a 'user:nobody allow add_file,delete_child' $parent;if($LASTEXITCODE-ne0){throw 'chmod failed to create the required macOS ACL fixture.'}
                $secretSpec=New-TestSecretSpec;$path=Join-Path $parent 'private.pem';$public=Join-Path $parent 'public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$path;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $true;$result.ReadCount|Should Be 2;$result.ErrorIds[0]|Should Be 'TrustAnchor.UnsafeParentAcl';$result.ErrorMessages[0]|Should Be 'The private trust-anchor parent must not have a macOS extended ACL.';(Test-Path -LiteralPath $path)|Should Be $false;(Test-Path -LiteralPath $public)|Should Be $false
            }

            # Scenario: A macOS 0700 parent has no extended ACL and receives both formal key-pair outputs.
            # Purpose: Accept Darwin ENOENT as the documented no-ACL result while keeping the production CLI boundary intact.
            It 'InterT70_creates_a_key_under_a_macOS_parent_without_an_extended_ACL' {
                $secretSpec=New-TestSecretSpec;$parent=Join-Path $TestDrive 'macos-no-acl-parent';[void][IO.Directory]::CreateDirectory($parent);chmod 700 $parent;$private=Join-Path $parent 'private.pem';$public=Join-Path $parent 'public.xml';$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec);$result.HadErrors|Should Be $false;(Test-Path -LiteralPath $private)|Should Be $true;(Test-Path -LiteralPath $public)|Should Be $true
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
            $index=0;foreach($fixture in $fixtures){[byte[]]$bytes=ConvertTo-TestUtf8Bytes $fixture;try{$path=Join-Path $TestDrive "closed-pem-$index.pem";$output=Join-Path $TestDrive "closed-pem-$index.xml";Write-TestPrivateKeyFixture $path $bytes;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1') @{PublicKeyPemPath=$path;OutputPath=$output};$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$index++}
        }finally{$rsa.Dispose()}
    }

    # Scenario: Private RSA XML fields use lower-case and namespace-prefixed element names.
    # Purpose: Require a byte-level closed element allowlist instead of case-sensitive private-field spotting.
    It 'UnitT50_rejects_case_or_namespace_variant_private_XML_at_the_byte_boundary' {
        $fixtures=@(
            '<RSAKeyValue><Modulus>AQ==</Modulus><Exponent>AQAB</Exponent><d>AQ==</d></RSAKeyValue>',
            '<RSAKeyValue xmlns:x="urn:private"><Modulus>AQ==</Modulus><Exponent>AQAB</Exponent><x:D>AQ==</x:D></RSAKeyValue>'
        )
        $index=0;foreach($fixture in $fixtures){[byte[]]$bytes=ConvertTo-TestUtf8Bytes $fixture;try{$path=Join-Path $TestDrive "closed-xml-$index.xml";Write-TestPrivateKeyFixture $path $bytes;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{PublicKeyXmlPath=$path};$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$index++}
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

    # Scenario: A bounded public-input fixture contains a sentinel and the formal conversion CLI rejects it after reading.
    # Purpose: Keep bounded input bytes out of every outer output surface while the cleanup table mutations bind failure-path clearing.
    It 'InterT52_clears_input_bytes_when_reading_fails_after_allocation' {
        $sentinel='bounded-input-sentinel-91c4e7b2';$path=Join-Path $TestDrive 'input-read-failure.pem';$output=Join-Path $TestDrive 'input-read-failure.xml';[byte[]]$bytes=ConvertTo-TestUtf8Bytes $sentinel
        try{[IO.File]::WriteAllBytes($path,$bytes);$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1') @{PublicKeyPemPath=$path;OutputPath=$output};$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat';Assert-TestSentinelAbsentFromCliSurfaces $result $sentinel @($output)}finally{[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)}
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
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;(Test-TrustAnchorFilePrimitiveSemantics $source)|Should Be $true;$mutated=$source.Replace('$acl=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect([Microsoft.Win32.SafeHandles.SafeFileHandle]$handle)','$acl=[SyuanTsai.AIInstructions.TrustAnchor.WindowsAclInspector]::Inspect([IO.File]::OpenHandle($Lease.Path))');(Test-TrustAnchorFilePrimitiveSemantics $mutated)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false
    }

    # Scenario: Runtime-generated PKCS#8 and PKCS#1 private DER are mislabeled with PUBLIC KEY armor.
    # Purpose: Reject non-SPKI DER while it is still held only in clearable byte arrays.
    It 'UnitT56_rejects_<Format>_private_DER_mislabeled_as_PUBLIC_KEY' -TestCases @(
        @{Format='PKCS8'},
        @{Format='PKCS1'}
    ) {
        param($Format)
        $rsa=[Security.Cryptography.RSA]::Create(3072);$der=$null;$bytes=$null
        try{[byte[]]$der=if($Format-ceq'PKCS8'){$rsa.ExportPkcs8PrivateKey()}else{$rsa.ExportRSAPrivateKey()};$bytes=ConvertTo-TestUtf8Bytes ([Security.Cryptography.PemEncoding]::WriteString('PUBLIC KEY',$der));$path=Join-Path $TestDrive "mislabeled-$Format.pem";$output=Join-Path $TestDrive "mislabeled-$Format.xml";Write-TestPrivateKeyFixture $path $bytes;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/ConvertTo-TrustAnchorPublicKeyXml.ps1') @{PublicKeyPemPath=$path;OutputPath=$output};$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Match '^TrustAnchor\.UnsupportedKeyFormat'}finally{if($null-ne$der){[Security.Cryptography.CryptographicOperations]::ZeroMemory($der)};if($null-ne$bytes){[Security.Cryptography.CryptographicOperations]::ZeroMemory($bytes)};$rsa.Dispose()}
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
        $valid=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1')
        $validTokens=$null;$validErrors=$null;$validAst=[Management.Automation.Language.Parser]::ParseInput($valid,[ref]$validTokens,[ref]$validErrors);@($validErrors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $validAst $contract)|Should Be $true
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
            $comment=if($entry.Value.Language-ceq'CSharp'){"// comment-only mutation`n"}else{"# comment-only mutation`n"};(Test-TrustAnchorProtectedContract $entry.Key ($comment+$source))|Should Be $true
        }
    }

    # Scenario: Every PowerShell/C# operation in the test, driver, AddScript payloads, and embedded sources is grouped by owner and exact shape.
    # Purpose: Derive module-private invocation policy from one complete purpose-annotated operation golden rather than an API-name denylist.
    It 'UnitT61_has_no_runtime_credential_private_module_calls' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$inventory=Get-TestCompleteOperationInventory $ast;(Test-TestCompleteOperationContract $inventory)|Should Be $true
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$injections=@(
            '$m=Microsoft.PowerShell.Core\Import-Module $script:ModulePath -PassThru;$m.NewBoundScriptBlock({Open-TrustAnchorPrivateKey $path}).InvokeReturnAsIs()',
            '$m=(Get-Variable Module -Scope Script).Value;$m.NewBoundScriptBlock({Read-TrustAnchorPassword}).InvokeReturnAsIs()',
            '$script:Module.SessionState.InvokeCommand.InvokeScript(''Get-Date'')'
        )
        foreach($injection in $injections){$mutatedTokens=$null;$mutatedErrors=$null;$mutatedAst=[Management.Automation.Language.Parser]::ParseInput(($source+"`n"+$injection),[ref]$mutatedTokens,[ref]$mutatedErrors);@($mutatedErrors).Count|Should Be 0;(Test-TestCompleteOperationContract (Get-TestCompleteOperationInventory $mutatedAst))|Should Be $false}
        $driver=Get-TestCliDriverSource;$driverTokens=$null;$driverErrors=$null;$driverAst=[Management.Automation.Language.Parser]::ParseInput($driver,[ref]$driverTokens,[ref]$driverErrors);@($driverErrors).Count|Should Be 0;$addScripts=@($driverAst.FindAll({param($node)$node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$node.Member.Value-ceq'AddScript'},$true)|Sort-Object{$_.Extent.StartOffset});$addScripts.Count|Should Be 2;$dynamic=Set-TestSourceSpan $driver $addScripts[1].Extent.StartOffset ($addScripts[1].Extent.EndOffset-$addScripts[1].Extent.StartOffset) '$powershell.AddScript($config.DynamicPayload)';(Test-TestCompleteOperationContract (Get-TestCompleteOperationInventory $ast $dynamic))|Should Be $false
    }

    # Scenario: Windows, Linux, and macOS discovery clauses are expanded, removed, and exchanged in real test source copies.
    # Purpose: Require each native case to remain under one exact single-variable native-host guard.
    It 'UnitT62_rejects_every_native_discovery_guard_mutation' {
        $source=(Get-Content -Raw -Encoding UTF8 $PSCommandPath).Replace("`r`n","`n").Replace("`r","`n")
        $mutations=[Collections.Generic.List[string]]::new()
        $mutations.Add($source.Replace('if($IsWindows){','if($IsWindows -or $true){'))
        $mutations.Add($source.Replace("        if(`$IsLinux){`n",'').Replace("        }`n        if(`$IsMacOS){","        if(`$IsMacOS){"))
        $tokens=$null;$errors=$null;$baseAst=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0
        $interT69=@($baseAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'It'-and[string]$node.CommandElements[1].Value-ceq'InterT69_rejects_a_macOS_extended_parent_ACL'},$true));$interT69.Count|Should Be 1
        $macIf=$interT69[0].Parent;while($null-ne$macIf-and$macIf-isnot[Management.Automation.Language.IfStatementAst]){$macIf=$macIf.Parent};$null-ne$macIf|Should Be $true
        $movedMac=Set-TestSourceSpan $source $interT69[0].Extent.StartOffset ($interT69[0].Extent.EndOffset-$interT69[0].Extent.StartOffset) ''
        $movedMac=Set-TestSourceSpan $movedMac $macIf.Extent.StartOffset 0 ($interT69[0].Extent.Text+"`n        ");$mutations.Add($movedMac)
        $swapped=$source.Replace('if($IsLinux){','if($NativeSwap){').Replace('if($IsMacOS){','if($IsLinux){').Replace('if($NativeSwap){','if($IsMacOS){');$mutations.Add($swapped)
        foreach($mutated in $mutations){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TestNativeRegistrationAst $ast)|Should Be $false}
    }

    # Scenario: Darwin ACL result constants and branch directions are reversed in real embedded-C# source copies.
    # Purpose: Bind ENOENT=2, acl_get_entry success=0, no-entry errno 2/22, and finally-based acl_free semantics.
    It 'UnitT63_binds_the_Darwin_ACL_ABI_semantics' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;$csharp=Get-TrustAnchorEmbeddedCSharpSource $source;(Test-TrustAnchorDarwinAclSemantics $csharp)|Should Be $true
        foreach($mutatedCSharp in @($csharp.Replace('if(result==0)throw','if(result==1)throw'),$csharp.Replace('if(error==2)return;','if(error==5)return;'))){(Test-TrustAnchorDarwinAclSemantics $mutatedCSharp)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $source.Replace($csharp,$mutatedCSharp))|Should Be $false}
    }

    # Scenario: Every reviewer-supplied password, command, and decoder mutation is applied to the real protected module source.
    # Purpose: Require both the semantic boundary and the independent whole-file golden to reject every known bypass.
    It 'UnitT64_rejects_every_secret_and_decoder_mutation_semantically_and_by_golden' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath
        $moduleMutations=@(
            $source.Replace('Read-TrustAnchorPassword -Confirm','Evil\Read-TrustAnchorPassword -Confirm'),
            $source.Replace("Microsoft.PowerShell.Utility\Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString","Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString:`$false"),
            $source.Replace("Microsoft.PowerShell.Utility\Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString","& Microsoft.PowerShell.Utility\Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString"),
            $source.Replace("Microsoft.PowerShell.Utility\Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString",". Microsoft.PowerShell.Utility\Read-Host 'Private-key password (minimum 16 characters)' -AsSecureString"),
            $source.Replace('    $first=Microsoft.PowerShell.Utility\Read-Host',"    `$readOptions=@{AsSecureString=`$true}`n    `$first=Microsoft.PowerShell.Utility\Read-Host").Replace("' -AsSecureString","' @readOptions"),
            $source.Replace('        return $Action.Invoke(@(,$characters))',"        if (`$characters[0] -ceq 'q') { throw (-join `$characters) }`n        return `$Action.Invoke(@(,`$characters))"),
            $source.Replace("    `$first=Microsoft.PowerShell.Utility\Read-Host", "    `$pipeline=@(`$input);if(`$pipeline.Count-gt0){return `$pipeline[0]}`n    `$first=Microsoft.PowerShell.Utility\Read-Host"),
            $source.Replace('$password=Read-TrustAnchorPassword -Confirm',"`$password=`$InjectedPassword;if(`$false){Read-TrustAnchorPassword -Confirm}"),
            $source.Replace('    $first=Microsoft.PowerShell.Utility\Read-Host',"    `$_=`$null`n    `$first=Microsoft.PowerShell.Utility\Read-Host"),
            $source.Replace('Read-TrustAnchorPassword -Confirm','Read-TrustAnchorPassword @confirmArguments'),
            ("`$script:TrustAnchorInteractiveStateTestHook=`$false`n"+$source.Replace('[Console]::IsInputRedirected','$script:TrustAnchorInteractiveStateTestHook')),
            $source.Replace('[Console]::IsInputRedirected',"`$env:TRUST_ANCHOR_INTERACTIVE_OVERRIDE -ceq '1'"),
            $source.Replace('[Console]::IsInputRedirected','$global:TrustAnchorInteractiveOverride')
        )
        foreach($mutated in $moduleMutations){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorPasswordSourceAst $ast)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
        $csharp=Get-TrustAnchorEmbeddedCSharpSource $source
        $decoderMutations=@(
            $csharp.Replace('RequirePublicXmlStructure(value);'+"`n"+'            return new System.Text.UTF8Encoding(false, true).GetString(value);','/* RequirePublicXmlStructure */'+"`n"+'            string text = new System.Text.UTF8Encoding(false, true).GetString(value);'+"`n"+'            RequirePublicXmlStructure(value);'+"`n"+'            return text;'),
            $csharp.Replace('DaclHex = dacl == IntPtr.Zero ? null : Convert.ToHexString(aclBytes)','DaclHex = null').Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            string leaked = Convert.ToHexString(value);'),
            $csharp.Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            string leaked = ""; for (int i = 0; i < value.Length; i++) leaked += (char)value[i];'),
            $csharp.Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            byte[] copy = value; string leaked = Convert.ToHexString(copy);'),
            $csharp.Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            byte[] copy = new byte[value.Length]; Array.Copy(value, copy, value.Length); string leaked = Convert.ToHexString(copy);'),
            $csharp.Replace('public static RSA DecodePublicPem(byte[] value) {','public static RSA DecodePublicPem(byte[] value) {'+"`n"+'            ReadOnlySpan<byte> copy = value.AsSpan(); string leaked = Convert.ToHexString(copy);')
        )
        foreach($mutatedCSharp in $decoderMutations){(Test-TrustAnchorPublicDecoderOperations $mutatedCSharp)|Should Be $false;$mutated=$source.Replace($csharp,$mutatedCSharp);(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}
    }

    # Scenario: Each C# and PowerShell cleanup point is independently removed and redirected to a different buffer in real module source.
    # Purpose: Bind every secret/input clear operation to its method, target local, and catch/finally control-flow location.
    It 'UnitT65_rejects_deletion_and_relocation_of_every_cleanup_point' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=(Get-Content -Raw -Encoding UTF8 $script:ModulePath).Replace("`r`n","`n").Replace("`r","`n");(Test-TrustAnchorCleanupContract $source)|Should Be $true;$csharp=Get-TrustAnchorEmbeddedCSharpSource $source;$analysis=Get-TrustAnchorCSharpAnalysis $csharp
        $csharpCalls=@()
        foreach($method in @($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$null-ne$_.Body})){foreach($operation in Get-TestCSharpOperations ($analysis.Model.GetOperation($method.Body))){if($operation.Kind-ceq[Microsoft.CodeAnalysis.OperationKind]::Invocation-and(($operation.TargetMethod.ContainingType.ToString()-ceq'System.Security.Cryptography.CryptographicOperations'-and$operation.TargetMethod.Name-ceq'ZeroMemory')-or($operation.TargetMethod.ContainingType.ToString()-ceq'SyuanTsai.AIInstructions.TrustAnchor.SecretBridge'-and$operation.TargetMethod.Name-ceq'Zero'))){$csharpCalls+=$operation}}}
        foreach($call in $csharpCalls){
            $deletedCSharp=Set-TestSourceSpan $csharp $call.Syntax.SpanStart $call.Syntax.Span.Length 'System.GC.KeepAlive(null)';$deleted=$source.Replace($csharp,$deletedCSharp);(Test-TrustAnchorCleanupContract $deleted)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $deleted)|Should Be $false
            $argument=$call.Arguments[0].Value.Syntax;$replacement=if($call.TargetMethod.Name-ceq'Zero'){'new char[1]'}else{'new byte[1]'};$relocatedCSharp=Set-TestSourceSpan $csharp $argument.SpanStart $argument.Span.Length $replacement;$relocated=$source.Replace($csharp,$relocatedCSharp);(Test-TrustAnchorCleanupContract $relocated)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $relocated)|Should Be $false
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

    # Scenario: The module qualifier, Force flag, or .NET-only path construction is independently weakened in each formal CLI import.
    # Purpose: Require a fresh fixed-path module instance before the guard and reject command-discovery path resolution semantically and by golden.
    It 'UnitT67_rejects_every_unqualified_non_forced_or_command_resolved_CLI_import' {
        foreach($name in (Get-TrustAnchorCliContracts).Keys){$relative="scripts/trust-anchor/$name";$source=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot $relative);$contract=(Get-TrustAnchorCliContracts)[$name];foreach($mutated in @($source.Replace('Microsoft.PowerShell.Core\Import-Module','Import-Module'),$source.Replace(' -PassThru -Force -ErrorAction',' -PassThru -ErrorAction'),$source.Replace("[IO.Path]::Combine(`$PSScriptRoot,'TrustAnchorPrivateKey.psm1')","Join-Path `$PSScriptRoot 'TrustAnchorPrivateKey.psm1'"))){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($mutated,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;(Test-TrustAnchorCliGuardAst $ast $contract)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutated)|Should Be $false}}
    }

    # Scenario: Each module top-level command, fixed platform-runtime path, and password reader is independently changed back to command discovery.
    # Purpose: Reject every pre-guard or credential-path shadowing mutation through the exact module semantic validator and complete golden.
    It 'UnitT81_rejects_unqualified_module_pre_guard_and_password_commands' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;(Test-TrustAnchorModulePreGuardAst $source)|Should Be $true
        $mutations=@(
            $source.Replace('Microsoft.PowerShell.Core\Set-StrictMode','Set-StrictMode'),
            $source.Replace("`$script:PlatformRuntimePath = [IO.Path]::GetFullPath([IO.Path]::Combine(`$PSScriptRoot, '..', 'platform-runtime.psd1'))","`$script:PlatformRuntimePath = Join-Path (Split-Path -Parent `$PSScriptRoot) '..\platform-runtime.psd1'"),
            $source.Replace('Microsoft.PowerShell.Core\Import-Module','Import-Module'),
            $source.Replace('Microsoft.PowerShell.Utility\Add-Type','Add-Type'),
            $source.Replace('Microsoft.PowerShell.Utility\Read-Host','Read-Host'),
            $source.Replace('Microsoft.PowerShell.Core\Export-ModuleMember','Export-ModuleMember')
        )
        foreach($mutant in $mutations){(Test-TrustAnchorModulePreGuardAst $mutant)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutant)|Should Be $false}
    }

    # Scenario: Join-Path, Split-Path, Import-Module, and Read-Host are shadowed in the caller session and point at a module that writes a load witness.
    # Purpose: Every formal CLI must reach TrustAnchor.NonInteractive through fixed adjacent dependencies without loading attacker-selected code or reading a shadowed password source.
    It 'InterT72_rejects_command_shadowing_before_loading_the_fixed_module' {
        foreach($name in (Get-TrustAnchorCliContracts).Keys){$parameters=switch($name){'New-TrustAnchorKeyPair.ps1'{@{KeyId='humanApproval';PrivateKeyPath=(Join-Path $TestDrive 'shadow-private.pem');PublicKeyXmlPath=(Join-Path $TestDrive 'shadow-public.xml')}}'ConvertTo-TrustAnchorPublicKeyXml.ps1'{@{PublicKeyPemPath=(Join-Path $TestDrive 'shadow-input.pem');OutputPath=(Join-Path $TestDrive 'shadow-output.xml')}}default{@{PublicKeyXmlPath=(Join-Path $TestDrive 'shadow-missing.xml')}}};$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot "scripts/trust-anchor/$name") $parameters -CiMarker CI -PreloadPathTamper;$result.HadErrors|Should Be $true;$result.ErrorIds[0]|Should Be 'TrustAnchor.NonInteractive';$result.PathTamperWitnessExists|Should Be $false;$result.ReadCount|Should Be 0}
    }

    # Scenario: Driver SecureString disposal and char-array clearing are deleted or redirected one point at a time.
    # Purpose: The exact finally inventory and post-cleanup boolean report must make every cleanup mutant fail through a formal CLI run.
    It 'UnitT73_rejects_driver_cleanup_deletion_and_relocation_mutations' {
        $driverSource=(Get-TestCliDriverSource).Replace("`r`n","`n").Replace("`r","`n");(Test-TestDriverCleanupContract $driverSource)|Should Be $true;$secretSpec=New-TestSecretSpec -Seed 731 -Length 24;$private=Join-Path $TestDrive 'cleanup-private.pem';$public=Join-Path $TestDrive 'cleanup-public.xml';$created=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/New-TrustAnchorKeyPair.ps1') @{KeyId='humanApproval';PrivateKeyPath=$private;PublicKeyXmlPath=$public} @($secretSpec,$secretSpec);$created.HadErrors|Should Be $false
        $baseline=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$private} @($secretSpec) -DriverSource $driverSource;$baseline.HadErrors|Should Be $false;(@($baseline.ResponseCleanupDisposed)-join',')|Should Be 'True';(@($baseline.ResponseCleanupZeroed)-join',')|Should Be 'True'
        $mutants=@(
            $driverSource.Replace('foreach($response in $responses){$response.Dispose()}','foreach($response in $responses){$null}'),
            $driverSource.Replace('$response.Dispose()','[Security.SecureString]::new().Dispose()'),
            $driverSource.Replace('foreach($characters in $responseCharacters){[Array]::Clear($characters,0,$characters.Length)}','foreach($characters in $responseCharacters){$null}'),
            $driverSource.Replace('[Array]::Clear($characters,0,$characters.Length)','[Array]::Clear([char[]]::new(1),0,1)')
        )
        $mutationIndex=0;foreach($mutant in $mutants){(Test-TestDriverCleanupContract $mutant)|Should Be $false;$result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{EncryptedPrivateKeyPath=$private} @($secretSpec) -DriverSource $mutant;$result.HadErrors|Should Be $false;$disposedReport=@($result.ResponseCleanupDisposed)-join',';$zeroedReport=@($result.ResponseCleanupZeroed)-join',';$cleanupFailed=$disposedReport-cne'True'-or$zeroedReport-cne'True';if(-not$cleanupFailed){throw "Driver cleanup mutant $mutationIndex survived: disposed=$disposedReport; zeroed=$zeroedReport."};$mutationIndex++}
    }

    # Scenario: Every rollback SameFile checkpoint and the shared pre-unlink link-count predicate is removed independently by Roslyn extent.
    # Purpose: Keep the general rollback error cases while proving each unobservable timing defense is still bound by both semantic and complete golden contracts.
    It 'UnitT79_rejects_every_rollback_identity_and_pre_unlink_link_count_deletion' {
        $relative='scripts/trust-anchor/TrustAnchorPrivateKey.psm1';$source=Get-Content -Raw -Encoding UTF8 $script:ModulePath;(Test-TrustAnchorRollbackSemantics $source)|Should Be $true;$csharp=Get-TrustAnchorEmbeddedCSharpSource $source;$analysis=Get-TrustAnchorCSharpAnalysis $csharp;$class=@($analysis.Root.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'ClassDeclarationSyntax'-and$_.Identifier.ValueText-ceq'UnixRollbackLease'})[0];$sameFileCalls=@($class.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'InvocationExpressionSyntax'-and$_.Expression.ToString()-ceq'SameFile'}|Sort-Object SpanStart);$sameFileCalls.Count|Should Be 5
        foreach($call in $sameFileCalls){$mutatedCSharp=Set-TestSourceSpan $csharp $call.SpanStart $call.Span.Length 'System.GC.KeepAlive(null)';$mutant=$source.Replace($csharp,$mutatedCSharp);(Test-TrustAnchorRollbackSemantics $mutant)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutant)|Should Be $false}
        $sameFileMethod=@($class.Members|Where-Object{$_.GetType().Name-ceq'MethodDeclarationSyntax'-and$_.Identifier.ValueText-ceq'SameFile'})[0];$linkCount=@($sameFileMethod.DescendantNodes()|Where-Object{$_.GetType().Name-ceq'BinaryExpressionSyntax'-and$_.OperatorToken.Text-ceq'!='-and$_.Left.ToString()-ceq'value.LinkCount'-and$_.Right.ToString()-ceq'1'});$linkCount.Count|Should Be 1;$mutatedCSharp=Set-TestSourceSpan $csharp $linkCount[0].SpanStart $linkCount[0].Span.Length 'false';$mutant=$source.Replace($csharp,$mutatedCSharp);(Test-TrustAnchorRollbackSemantics $mutant)|Should Be $false;(Test-TrustAnchorProtectedContract $relative $mutant)|Should Be $false
    }

    # Scenario: Every test-side clear/dispose operation is bound to its owner, exact target, and finally/body context, then deleted and redirected independently.
    # Purpose: Make all plaintext private/secret cleanup points, including the standalone PKCS#8 PEM buffers, fail closed under deletion or wrong-target relocation.
    It 'UnitT80_rejects_deletion_and_wrong_target_relocation_of_every_test_cleanup_point' {
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$inventory=Get-TestSecretCleanupInventory $ast;(Test-TestSecretCleanupContract $inventory)|Should Be $true
        foreach($entry in $inventory.Entries){
            $deleted=Set-TestSourceSpan $source $entry.Node.Extent.StartOffset ($entry.Node.Extent.EndOffset-$entry.Node.Extent.StartOffset) '$null';$deletedTokens=$null;$deletedErrors=$null;$deletedAst=[Management.Automation.Language.Parser]::ParseInput($deleted,[ref]$deletedTokens,[ref]$deletedErrors);@($deletedErrors).Count|Should Be 0;(Test-TestSecretCleanupContract (Get-TestSecretCleanupInventory $deletedAst))|Should Be $false
            $replacement=switch -CaseSensitive($entry.Api){'ZeroMemory'{'[Security.Cryptography.CryptographicOperations]::ZeroMemory([byte[]]::new(1))'}'ZeroCharacters'{'[SyuanTsai.AIInstructions.TrustAnchor.SecretBridge]::Zero([char[]]::new(1))'}'ArrayClear'{'[Array]::Clear([char[]]::new(1),0,1)'}'Dispose'{'([Security.SecureString]::new()).Dispose()'}};$relocated=Set-TestSourceSpan $source $entry.Node.Extent.StartOffset ($entry.Node.Extent.EndOffset-$entry.Node.Extent.StartOffset) $replacement;$relocatedTokens=$null;$relocatedErrors=$null;$relocatedAst=[Management.Automation.Language.Parser]::ParseInput($relocated,[ref]$relocatedTokens,[ref]$relocatedErrors);@($relocatedErrors).Count|Should Be 0;(Test-TestSecretCleanupContract (Get-TestSecretCleanupInventory $relocatedAst))|Should Be $false
        }
    }

    # Scenario: The complete purpose-annotated test/driver operation golden is mutated with five alternate file-write shapes, including embedded C#.
    # Purpose: Derive private-fixture and artifact policy from all operations, so any new command/member/constructor fails without naming dangerous APIs first.
    It 'UnitT71_closes_private_fixture_writes_and_driver_artifact_surfaces' {
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$inventory=Get-TestCompleteOperationInventory $ast;(Test-TestCompleteOperationContract $inventory)|Should Be $true;$source=Get-Content -Raw -Encoding UTF8 $PSCommandPath
        $csharpInjection=[string]::Join("`n",@('$operationInventoryCSharp=@''','using System.IO; class OperationInventoryMutation { void Leak(byte[] value) { using (FileStream stream = File.OpenWrite("private.pem")) { stream.Write(value,0,value.Length); } } }','''@'))
        $injections=@(
            '$writer=[IO.File]::CreateText($privatePath);try{$writer.WriteLine([Convert]::ToBase64String($privateBytes))}finally{$writer.Dispose()}',
            '$writer=[IO.StreamWriter]::new($privatePath);try{$writer.WriteLine([Convert]::ToBase64String($privateBytes))}finally{$writer.Dispose()}',
            '$privateBytes|Tee-Object -FilePath $privatePath|Out-Null',
            '$stream=[IO.File]::OpenWrite($privatePath);try{foreach($value in $privateBytes){$stream.WriteByte($value)}}finally{$stream.Dispose()}',
            $csharpInjection
        )
        foreach($injection in $injections){$mutationTokens=$null;$mutationErrors=$null;$mutationAst=[Management.Automation.Language.Parser]::ParseInput(($source+"`n"+$injection),[ref]$mutationTokens,[ref]$mutationErrors);@($mutationErrors).Count|Should Be 0;(Test-TestCompleteOperationContract (Get-TestCompleteOperationInventory $mutationAst))|Should Be $false}
        $result=Invoke-TestTrustAnchorCli (Join-Path $script:RepositoryRoot 'scripts/trust-anchor/Get-TrustAnchorFingerprint.ps1') @{PublicKeyXmlPath=(Join-Path $TestDrive 'missing.xml')} -CiMarker CI;$sentinel='config-artifact-sentinel-8c4a2f19';$contents=@($result.ArtifactContents);$contents[1]=$sentinel;$mutated=[pscustomobject]@{EnvironmentContainsSentinel=$result.EnvironmentContainsSentinel;Stdout=$result.Stdout;Stderr=$result.Stderr;Transcript=$result.Transcript;Output=$result.Output;ErrorIds=$result.ErrorIds;ErrorMessages=$result.ErrorMessages;ArtifactContents=$contents;SurfacePaths=$result.SurfacePaths};(Test-TestSentinelAbsentFromCliSurfaces $mutated $sentinel)|Should Be $false;foreach($path in $result.SurfacePaths){(Test-Path -LiteralPath $path)|Should Be $false}
    }
}

Describe 'PR-K1 trust-anchor regression inventory' {
    AfterAll {Remove-Module $script:Module.Name -Force -ErrorAction SilentlyContinue}

    # Scenario: The test AST is inspected for native-host registration and runtime-only RSA generation.
    # Purpose: Every platform-specific It must live below one explicit native Windows/Unix conditional without committed keys or skips.
    It 'UnitT55_registers_the_fixed_native_inventory_under_the_correct_AST_clause' {
        $windows=@('InterT31_share_lock_explicitly_prevents_pathname_replacement','InterT32_delete_sharing_fixture_proves_handle_based_DACL_evidence','InterT33_rejects_a_private_key_leaf_reparse_point','InterT34_formal_creation_has_an_independently_verified_restrictive_DACL','InterT35_ConPTY_survives_the_official_closed_stdin_shard_transport','InterT75_Windows_post_open_revalidation_deletion_mutants_fail_their_barrier_contracts','InterT78_Windows_directory_share_mutant_allows_rename_and_fails_the_lease_contract')
        $unix=@('InterT40_accepts_owner_only_mode_0400','InterT41_rejects_the_original_broad_mode_after_pathname_replacement','InterT42_rejects_metadata_change_during_read','InterT43_rejects_a_private_key_leaf_symbolic_link','InterT44_formal_creation_has_an_independently_verified_owner_only_mode','InterT45_rejects_post_read_identity_replacement_when_both_files_are_restrictive','InterT76_Unix_post_open_revalidation_deletion_mutants_fail_their_barrier_contracts','InterT77_Unix_parent_identity_revalidation_deletion_mutant_fails_the_barrier_contract','InterT46_rollback_fails_closed_when_the_tombstone_is_replaced_before_unlink','InterT47_rollback_fails_closed_when_a_hard_link_appears_before_unlink','InterT48_enforces_the_rollback_parent_boundary_for_<Mode>','InterT68_rejects_a_Linux_named_user_writable_parent_ACL','InterT69_rejects_a_macOS_extended_parent_ACL','InterT70_creates_a_key_under_a_macOS_parent_without_an_extended_ACL')
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);@($errors).Count|Should Be 0;$conditional=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst]-and@($node.FindAll({param($child)$child-is[Management.Automation.Language.CommandAst]-and$child.GetCommandName()-ceq'Describe'-and[string]$child.CommandElements[1].Value-cin@('PR-K1 Windows native handle safety','PR-K1 Unix native handle safety')},$true)).Count-eq2},$true));$conditional.Count|Should Be 1;(Test-TestExactSingleVariableCondition $conditional[0].Clauses[0].Item1 'IsWindows')|Should Be $true;(Test-TestNativeRegistrationAst $ast)|Should Be $true;$windowsExtent=$conditional[0].Clauses[0].Item2.Extent;$unixExtent=$conditional[0].ElseClause.Extent;$nativeIts=@($conditional[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));$actualWindows=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$windowsExtent.StartOffset-and$_.Extent.EndOffset-le$windowsExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});$actualUnix=@($nativeIts|Where-Object{$_.Extent.StartOffset-ge$unixExtent.StartOffset-and$_.Extent.EndOffset-le$unixExtent.EndOffset}|ForEach-Object{[string]$_.CommandElements[1].Value});($actualWindows-join'|')|Should Be ($windows-join'|');($actualUnix-join'|')|Should Be ($unix-join'|');@($nativeIts).Count|Should Be ($windows.Count+$unix.Count)
        $allIts=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'It'},$true));foreach($name in @($windows+$unix)){$matches=@($allIts|Where-Object{[string]$_.CommandElements[1].Value-ceq$name});$matches.Count|Should Be 1;($matches[0].Extent.StartOffset-ge$conditional[0].Extent.StartOffset-and$matches[0].Extent.EndOffset-le$conditional[0].Extent.EndOffset)|Should Be $true};$numbers=@($allIts|ForEach-Object{if([string]$_.CommandElements[1].Value-match'^(?:Unit|Inter)T(\d{2})_'){$Matches[1]}});@($numbers|Group-Object|Where-Object Count-gt1).Count|Should Be 0
        $source=Get-Content -Raw -Encoding UTF8 $PSCommandPath;$source|Should Match 'RSA\]::Create\(3072\)';$source|Should Not Match 'BEGIN (RSA )?PRIVATE KEY';(Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'docs/standards/core-test-skip-inventory.json'))|Should Not Match 'trust-anchor-tools'
    }
}
