Set-StrictMode -Version Latest

function Get-ProviderAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName
    )

    switch ($ResourceName) {
        'codexMain' {
            return [pscustomobject]@{
                provider = $ResourceName
                executable = 'codex'
                primaryProbe = [pscustomobject]@{ mode = 'status'; command = 'codex'; arguments = @('login', 'status') }
                diagnosticProbe = [pscustomobject]@{ command = 'codex'; arguments = @('--version') }
                usageSource = 'unsupported'
                model = $null
                install = [pscustomobject]@{ command = 'npm'; arguments = @('install', '--global', '@openai/codex') }
                login = [pscustomobject]@{ command = 'codex'; arguments = @('login') }
            }
        }
        'codexSpark' {
            return [pscustomobject]@{
                provider = $ResourceName
                executable = 'codex'
                primaryProbe = [pscustomobject]@{ mode = 'status'; command = 'codex'; arguments = @('login', 'status') }
                diagnosticProbe = [pscustomobject]@{ command = 'codex'; arguments = @('--version') }
                usageSource = 'unsupported'
                model = 'gpt-5.3-codex-spark'
                install = [pscustomobject]@{ command = 'npm'; arguments = @('install', '--global', '@openai/codex') }
                login = [pscustomobject]@{ command = 'codex'; arguments = @('login') }
            }
        }
        { $_ -in @('copilotPersonal', 'copilotCompany') } {
            return [pscustomobject]@{
                provider = $ResourceName
                executable = 'copilot'
                primaryProbe = [pscustomobject]@{ mode = 'execution'; command = 'copilot'; arguments = @() }
                diagnosticProbe = [pscustomobject]@{ command = 'copilot'; arguments = @('version') }
                usageSource = 'unsupported'
                model = $null
                install = [pscustomobject]@{
                    command = 'winget'
                    arguments = @('install', '--id', 'GitHub.Copilot', '--exact', '--accept-package-agreements', '--accept-source-agreements')
                }
                login = [pscustomobject]@{ command = 'copilot'; arguments = @('login') }
            }
        }
        'agy' {
            return [pscustomobject]@{
                provider = $ResourceName
                executable = 'agy'
                primaryProbe = [pscustomobject]@{ mode = 'status'; command = 'agy'; arguments = @('models') }
                diagnosticProbe = [pscustomobject]@{ command = 'agy'; arguments = @('--help') }
                usageSource = 'unsupported'
                model = $null
                install = [pscustomobject]@{
                    command = 'powershell.exe'
                    arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "irm 'https://antigravity.google/cli/install.ps1' | iex")
                }
                login = [pscustomobject]@{ command = 'agy'; arguments = @() }
            }
        }
        'junie' {
            return [pscustomobject]@{
                provider = $ResourceName
                executable = 'junie'
                primaryProbe = [pscustomobject]@{ mode = 'execution'; command = 'junie'; arguments = @() }
                diagnosticProbe = [pscustomobject]@{ command = 'junie'; arguments = @('--version') }
                usageSource = 'unsupported'
                model = $null
                install = [pscustomobject]@{
                    command = 'powershell.exe'
                    arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "iex (irm 'https://junie.jetbrains.com/install.ps1')")
                }
                login = [pscustomobject]@{ command = 'junie'; arguments = @() }
            }
        }
    }
}

function Get-ResourceEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [string] $StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = if (-not [string]::IsNullOrWhiteSpace($env:AI_CLI_STATE_HOME)) {
            $env:AI_CLI_STATE_HOME
        }
        else {
            Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-cli-environment'
        }
    }

    $environment = @{}
    if ($ResourceName -in @('copilotPersonal', 'copilotCompany')) {
        $profile = if ($ResourceName -eq 'copilotPersonal') { 'personal' } else { 'company' }
        $environment.COPILOT_HOME = Join-Path (Join-Path $StateRoot 'copilot') $profile

        $tokenVariable = if ($profile -eq 'personal') {
            'AI_CLI_COPILOT_PERSONAL_TOKEN'
        }
        else {
            'AI_CLI_COPILOT_COMPANY_TOKEN'
        }
        $token = [Environment]::GetEnvironmentVariable($tokenVariable)
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $environment.COPILOT_GITHUB_TOKEN = $token
        }
    }

    return $environment
}

function Resolve-CopilotProfileAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('copilotPersonal', 'copilotCompany')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [psobject] $ResourceConfig,

        [hashtable] $Environment = @{}
    )

    if ($ResourceConfig.authenticationMode -eq 'token') {
        $tokenReady = $Environment.ContainsKey('COPILOT_GITHUB_TOKEN') -and
            -not [string]::IsNullOrWhiteSpace([string] $Environment.COPILOT_GITHUB_TOKEN)
        return [pscustomobject]@{
            ready = $tokenReady
            reason = if ($tokenReady) { $null } else { 'authentication_required' }
            source = if ($tokenReady) { 'token' } else { 'profile_token_missing' }
        }
    }

    return [pscustomobject]@{
        ready = $true
        reason = $null
        source = 'stored'
    }
}

function Get-JunieConsumptionMode {
    [CmdletBinding()]
    param(
        [hashtable] $Environment = @{}
    )

    $byokVariables = @(
        'JUNIE_ANTHROPIC_API_KEY',
        'JUNIE_OPENAI_API_KEY',
        'JUNIE_GOOGLE_API_KEY',
        'JUNIE_GROK_API_KEY',
        'JUNIE_OPENROUTER_API_KEY'
    )

    foreach ($variable in $byokVariables) {
        if ($Environment.ContainsKey($variable) -and -not [string]::IsNullOrWhiteSpace([string] $Environment[$variable])) {
            return [pscustomobject]@{ consumptionMode = 'byok'; consumptionModeVerified = $true }
        }
    }

    if ($Environment.ContainsKey('JUNIE_API_KEY') -and
        -not [string]::IsNullOrWhiteSpace([string] $Environment.JUNIE_API_KEY)) {
        return [pscustomobject]@{ consumptionMode = 'jetbrains-ai'; consumptionModeVerified = $true }
    }

    return [pscustomobject]@{ consumptionMode = 'unknown'; consumptionModeVerified = $false }
}
