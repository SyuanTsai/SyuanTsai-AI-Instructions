#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$copilotRoot = Join-Path $PSScriptRoot 'copilot'
. (Join-Path $copilotRoot 'credentials.ps1')

$secureToken = Read-Host 'Enter the dedicated GitHub Copilot Personal token' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$plainToken = $null

try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw 'A non-empty Personal token is required.'
    }

    Set-CopilotCredential -Profile 'personal' -Token $plainToken
    [Environment]::SetEnvironmentVariable('AI_CLI_COPILOT_PERSONAL_TOKEN', $null, 'User')
    $env:COPILOT_GITHUB_TOKEN = $plainToken
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    $env:COPILOT_HOME = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-cli-environment\copilot\personal'

    Set-Location -LiteralPath ([System.IO.Path]::GetFullPath($RepositoryRoot))
    Write-Host 'The Personal token was saved to Windows Credential Manager. Copilot will now start with the isolated Personal profile.' -ForegroundColor Green
    & copilot
    exit $(if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE })
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
    $plainToken = $null
    Remove-Item Env:COPILOT_GITHUB_TOKEN -ErrorAction SilentlyContinue
}
