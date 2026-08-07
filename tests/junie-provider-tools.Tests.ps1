$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:ToolsRoot = Join-Path $script:SkillRoot 'assets\environment-layer\tools'
$script:CommonImportScript = Join-Path $script:ToolsRoot 'common\import.ps1'

. $script:CommonImportScript

Describe 'Junie provider tool structure' {
    # Scenario: Junie owns the same provider entry points as Codex and Copilot.
    # Purpose: Keep login, diagnostics, and machine-readable usage discovery predictable for callers.
    It 'T010_exposes_login_usage_and_doctor_entry_points' {
        # Given
        $providerFiles = @('usage.ps1', 'login.ps1', 'get-usage.ps1', 'doctor.ps1')

        # When
        $adapter = Get-ProviderAdapter -ResourceName 'junie'

        # Then
        foreach ($file in $providerFiles) {
            Test-Path -LiteralPath (Join-Path $script:ToolsRoot "junie\$file") -PathType Leaf | Should Be $true
        }
        $adapter.usageSource | Should Be 'junie-interactive-usage'
    }
}

Describe 'Junie machine-readable usage boundary' {
    # Scenario: Junie exposes account and session usage only through its interactive TUI.
    # Purpose: Keep automation honest by returning UNKNOWN instead of scraping terminal content or inventing a total.
    It 'T010_returns_interactive_only_unknown_usage' {
        # Given / When
        $usage = New-JunieUsageSnapshot

        # Then
        $usage.provider | Should Be 'junie'
        $usage.source | Should Be 'junie-interactive-usage'
        $usage.acquisitionMode | Should Be 'interactive'
        $usage.machineReadable | Should Be $false
        $usage.known | Should Be $false
        $usage.usageAmountKnown | Should Be $false
        $usage.usedPercent | Should Be $null
        $usage.usedQuantity | Should Be $null
        $usage.limitQuantity | Should Be $null
        $usage.reason | Should Be 'interactive_usage_only'
        $usage.humanReviewAction | Should Be 'tools/ai-usage.ps1 -InteractiveResourceName junie'
    }

    # Scenario: An administrator explicitly supplies a filtered Central Console export and its numeric column names.
    # Purpose: Keep the Junie provider entry point consistent while delegating parsing to the source-owned CSV adapter.
    It 'T020_delegates_explicit_central_console_import_to_the_source_adapter' {
        # Given
        $csvPath = Join-Path $TestDrive 'junie-ai-credits.csv'
        @'
Spent,Quota
15,60
'@ | Set-Content -LiteralPath $csvPath -Encoding utf8
        $scriptPath = Join-Path $script:ToolsRoot 'junie\get-usage.ps1'

        # When
        $usage = & $scriptPath `
            -CentralConsoleCsvPath $csvPath `
            -UsedColumn 'Spent' `
            -LimitColumn 'Quota' |
            ConvertFrom-Json

        # Then
        $usage.acquisitionMode | Should Be 'csv_import'
        $usage.source | Should Be 'jetbrains-central-console-csv'
        $usage.known | Should Be $true
        $usage.usedPercent | Should Be 25
    }
}

Describe 'Junie provider diagnostics' {
    # Scenario: Junie is installed and a Junie API key is available for headless execution.
    # Purpose: Report the verified consumption mode without returning the credential or guessing interactive account state.
    It 'T010_reports_headless_readiness_without_exposing_credentials' {
        # Given
        $commandResolver = { [pscustomobject]@{ Source = 'C:\tools\junie.exe' } }
        $versionRunner = {
            param($Command, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; stdout = 'Junie CLI 1.2.3'; stderr = '' }
        }

        # When
        $state = Get-JunieDoctorState `
            -CredentialEnvironment @{ JUNIE_API_KEY = 'private-junie-test-token' } `
            -CommandResolver $commandResolver `
            -VersionRunner $versionRunner

        # Then
        $state.installed | Should Be $true
        $state.version | Should Be 'Junie CLI 1.2.3'
        $state.headlessCredentialReady | Should Be $true
        $state.consumptionMode | Should Be 'jetbrains-ai'
        $state.consumptionModeVerified | Should Be $true
        $state.interactiveCredentialReady | Should Be $null
        $state.usage.reason | Should Be 'interactive_usage_only'
        ($state | ConvertTo-Json -Depth 10) | Should Not Match 'private-junie-test-token'
    }

    # Scenario: Junie is not installed and no documented headless credential is present.
    # Purpose: Distinguish installation and headless-auth readiness while preserving the user-controlled login option.
    It 'T020_reports_missing_cli_and_headless_credential_separately' {
        # Given
        $commandResolver = { $null }

        # When
        $state = Get-JunieDoctorState `
            -CredentialEnvironment @{} `
            -CommandResolver $commandResolver

        # Then
        $state.installed | Should Be $false
        $state.installationReason | Should Be 'command_not_found'
        $state.headlessCredentialReady | Should Be $false
        $state.headlessAuthenticationReason | Should Be 'headless_credential_required'
        $state.authenticationAction | Should Be 'interactive_login_or_configure_headless_key'
        $state.consumptionMode | Should Be 'unknown'
        $state.usage.known | Should Be $false
    }
}
