#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$secureToken = Read-Host 'Enter the dedicated GitHub Copilot Personal token' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$plainToken = $null

try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw 'A non-empty Personal token is required.'
    }

    [Environment]::SetEnvironmentVariable('AI_CLI_COPILOT_PERSONAL_TOKEN', $plainToken, 'User')
    $env:COPILOT_GITHUB_TOKEN = $plainToken
    $env:COPILOT_HOME = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-cli-environment\copilot\personal'

    Set-Location -LiteralPath ([System.IO.Path]::GetFullPath($RepositoryRoot))
    Write-Host 'The Personal token was saved to your user environment. Copilot will now start with the isolated Personal profile.' -ForegroundColor Green
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
