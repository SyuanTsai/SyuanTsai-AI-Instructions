. (Join-Path $PSScriptRoot 'ai-instructions-writer-gate.TestSupport.ps1')

$script:HasWindowsPowerShell51=$false
if($env:OS-ceq'Windows_NT'-and$null-ne(Get-Command powershell.exe -ErrorAction SilentlyContinue)){
    $desktopVersion=(& powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'|Select-Object -Last 1)
    $script:HasWindowsPowerShell51=[string]$desktopVersion-like'5.1.*'
}
if($script:HasWindowsPowerShell51){
    Describe 'AI instructions v3 launcher Windows PowerShell baseline' {
        # Scenario: Windows PowerShell 5.1 opens an installed v3/v5 runtime.
        # Purpose: Register only on a real 5.1 host and return runtime-baseline-unavailable without a skip.
        It 'InterT100_refuses_v3v5_on_Windows_PowerShell_5_1' {
            $shortParent=Join-Path ([IO.Path]::GetTempPath()) 'p7e';$root=Join-Path $shortParent ([Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $root|Out-Null
            try{
                $candidate=Join-Path $root 'src';New-P7eV3Candidate $candidate;$fixtureHome=Join-Path $root 'home';$install=Invoke-P7eInstaller -SourceRoot $candidate -CodexHome $fixtureHome -WriterSchema V3V5;$install.ExitCode|Should Be 0
                $before=Get-P7eTreeSnapshot $fixtureHome;$result=Invoke-P7eLauncherFailure -CodexHome $fixtureHome -Desktop
                $result.ExitCode|Should Not Be 0;(Get-AiInstructionsRefusalCode $result.Output)|Should Be runtime-baseline-unavailable
                (Get-P7eTreeSnapshot $fixtureHome)|Should Be $before
            }finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
        }
    }
}
