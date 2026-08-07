$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:RuntimeRoot = Join-Path $script:SkillRoot 'assets\environment-layer'
$script:ImportScript = Join-Path $script:RuntimeRoot 'tools\common\import.ps1'
$script:InstallScript = Join-Path $script:SkillRoot 'scripts\install-ai-cli-environment.ps1'

. $script:ImportScript
. $script:InstallScript

function New-TestAiConfiguration {
    param(
        [ValidateSet('allow', 'warn', 'deny')]
        [string] $UnknownUsagePolicy = 'warn',

        [bool] $AgyEnabled = $true,

        [int] $AgyHardLimitPercent = 100
    )

    return [pscustomobject]@{
        schemaVersion = 1
        unknownUsagePolicy = $UnknownUsagePolicy
        resources = [pscustomobject]@{
            codexMain = [pscustomobject]@{ enabled = $true; hardLimitPercent = 90 }
            codexSpark = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100; model = 'gpt-5.3-codex-spark' }
            copilotPersonal = [pscustomobject]@{ enabled = $true; hardLimitPercent = 80; profile = 'personal'; authenticationMode = 'token' }
            copilotCompany = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100; profile = 'company'; authenticationMode = 'stored' }
            agy = [pscustomobject]@{ enabled = $AgyEnabled; hardLimitPercent = $AgyHardLimitPercent }
            junie = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100 }
        }
    }
}

function New-TestProcessResult {
    param(
        [int] $ExitCode = 0,
        [string] $StdOut = '',
        [string] $StdErr = '',
        [bool] $CommandNotFound = $false,
        [bool] $TimedOut = $false,
        [AllowNull()]
        [string] $StartError = $null
    )

    return [pscustomobject]@{
        started = -not $CommandNotFound
        exitCode = $ExitCode
        stdout = $StdOut
        stderr = $StdErr
        commandNotFound = $CommandNotFound
        timedOut = $TimedOut
        startError = $StartError
        durationMs = 1
    }
}

Describe 'AI CLI resource policy' {
    # Scenario: The configured resource is disabled before any external work begins.
    # Purpose: Protect the no-probe, no-login, and no-execution guarantee for disabled resources.
    It 'T010_returns_resource_disabled_without_invoking_the_primary_probe' {
        # Given
        $configuration = New-TestAiConfiguration -AgyEnabled $false
        $script:probeCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:probeCalls++
            New-TestProcessResult
        }

        # When
        $result = Invoke-ResourceAvailability -ResourceName 'agy' -Configuration $configuration -ProcessRunner $processRunner

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_disabled'
        $script:probeCalls | Should Be 0
    }

    # Scenario: Usage is unknown and policy is allow, warn, or deny.
    # Purpose: Ensure null usage is never interpreted as zero and every supported policy is enforced.
    It 'T020_applies_each_unknown_usage_policy_without_guessing_usage' {
        # Given / When
        $allow = Resolve-UsageAvailability -UsageKnown $false -UsedPercent $null -HardLimitPercent 80 -UnknownUsagePolicy 'allow'
        $warn = Resolve-UsageAvailability -UsageKnown $false -UsedPercent $null -HardLimitPercent 80 -UnknownUsagePolicy 'warn'
        $deny = Resolve-UsageAvailability -UsageKnown $false -UsedPercent $null -HardLimitPercent 80 -UnknownUsagePolicy 'deny'

        # Then
        $allow.available | Should Be $true
        $allow.warning | Should Be $null
        $warn.available | Should Be $true
        $warn.warning | Should Be 'usage_unknown'
        $deny.available | Should Be $false
        $deny.reason | Should Be 'usage_unknown'
    }

    # Scenario: Current usage equals the configured hard limit.
    # Purpose: Protect the inclusive usedPercent >= hardLimitPercent guard.
    It 'T030_rejects_usage_equal_to_the_hard_limit' {
        # Given / When
        $result = Resolve-UsageAvailability -UsageKnown $true -UsedPercent 85 -HardLimitPercent 85 -UnknownUsagePolicy 'warn'

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_hard_limit_reached'
        $result.usedPercent | Should Be 85
        $result.hardLimitPercent | Should Be 85
    }

    # Scenario: Usage is below the configured hard limit.
    # Purpose: Ensure independent limits allow a resource that remains below its threshold.
    It 'T040_allows_usage_below_the_hard_limit' {
        # Given / When
        $result = Resolve-UsageAvailability -UsageKnown $true -UsedPercent 84.9 -HardLimitPercent 85 -UnknownUsagePolicy 'warn'

        # Then
        $result.available | Should Be $true
        $result.reason | Should Be $null
    }
}

Describe 'AI CLI probe classification and retry' {
    # Scenario: Provider failures expose distinct missing, auth, permission, network, timeout, and provider reasons.
    # Purpose: Prevent a failed usage probe from being misclassified as missing or unauthenticated.
    It 'T010_classifies_probe_failures_without_collapsing_distinct_causes' {
        # Given / When / Then
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -CommandNotFound $true)).reason | Should Be 'command_not_found'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -StartError 'permission_denied')).reason | Should Be 'permission_denied'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -ExitCode 1 -TimedOut $true)).reason | Should Be 'timeout'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -ExitCode 1 -StdErr 'Please sign in to continue')).reason | Should Be 'authentication_required'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -ExitCode 1 -StdErr 'Access is denied')).reason | Should Be 'permission_denied'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -ExitCode 1 -StdErr 'TLS connection timed out')).reason | Should Be 'network_error'
        (Classify-ProbeFailure -ProcessResult (New-TestProcessResult -ExitCode 1 -StdErr 'provider rejected request')).reason | Should Be 'provider_error'
    }

    # Scenario: A successful Codex primary probe returns usage unknown.
    # Purpose: Ensure the happy path runs one information-rich probe and no redundant install or login action.
    It 'T020_uses_one_primary_probe_without_redundant_preflight_commands' {
        # Given
        $configuration = New-TestAiConfiguration
        $script:probeCalls = 0
        $script:installCalls = 0
        $script:loginCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:probeCalls++
            New-TestProcessResult -StdOut 'Logged in using ChatGPT'
        }
        $installer = { param($ResourceName, $Adapter) $script:installCalls++ }
        $loginRunner = { param($ResourceName, $Adapter, $Environment) $script:loginCalls++ }

        # When
        $result = Invoke-ResourceAvailability -ResourceName 'codexMain' -Configuration $configuration -ProcessRunner $processRunner -Installer $installer -LoginRunner $loginRunner -Repair

        # Then
        $result.available | Should Be $true
        $result.authenticationReady | Should Be $true
        $result.usageKnown | Should Be $false
        $result.warning | Should Be 'usage_unknown'
        $script:probeCalls | Should Be 1
        $script:installCalls | Should Be 0
        $script:loginCalls | Should Be 0
    }

    # Scenario: The primary probe reports that the executable is missing, then succeeds after install.
    # Purpose: Verify lazy bootstrap is idempotent in flow and retries only the primary probe once.
    It 'T030_installs_only_after_command_not_found_and_retries_the_primary_probe_once' {
        # Given
        $configuration = New-TestAiConfiguration
        $script:probeCalls = 0
        $script:installCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:probeCalls++
            if ($script:probeCalls -eq 1) {
                return New-TestProcessResult -CommandNotFound $true
            }
            return New-TestProcessResult -StdOut 'Available models: model-a'
        }
        $installer = { param($ResourceName, $Adapter) $script:installCalls++; return $true }

        # When
        $result = Invoke-ResourceAvailability -ResourceName 'agy' -Configuration $configuration -ProcessRunner $processRunner -Installer $installer -Repair

        # Then
        $result.available | Should Be $true
        $result.bootstrapAction | Should Be 'installed'
        $script:probeCalls | Should Be 2
        $script:installCalls | Should Be 1
    }

    # Scenario: The primary probe reports authentication required, then succeeds after official login.
    # Purpose: Verify login is diagnostic fallback and only the primary probe is retried.
    It 'T040_logs_in_only_after_authentication_error_and_retries_the_primary_probe_once' {
        # Given
        $configuration = New-TestAiConfiguration
        $script:probeCalls = 0
        $script:loginCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:probeCalls++
            if ($script:probeCalls -eq 1) {
                return New-TestProcessResult -ExitCode 1 -StdErr 'You are not logged into Antigravity'
            }
            return New-TestProcessResult -StdOut 'Available models: model-a'
        }
        $loginRunner = { param($ResourceName, $Adapter, $Environment) $script:loginCalls++; return $true }

        # When
        $result = Invoke-ResourceAvailability -ResourceName 'agy' -Configuration $configuration -ProcessRunner $processRunner -LoginRunner $loginRunner -Repair

        # Then
        $result.available | Should Be $true
        $result.authenticationAction | Should Be 'completed'
        $script:probeCalls | Should Be 2
        $script:loginCalls | Should Be 1
    }

    # Scenario: The official login flow does not complete successfully.
    # Purpose: Distinguish a failed repair attempt from the initial authentication-required diagnosis.
    It 'T050_reports_authentication_failed_when_the_login_flow_fails' {
        # Given
        $configuration = New-TestAiConfiguration
        $script:probeCalls = 0
        $script:loginCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:probeCalls++
            New-TestProcessResult -ExitCode 1 -StdErr 'You are not logged into Antigravity'
        }
        $loginRunner = { param($ResourceName, $Adapter, $Environment) $script:loginCalls++; return $false }

        # When
        $result = Invoke-ResourceAvailability -ResourceName 'agy' -Configuration $configuration -ProcessRunner $processRunner -LoginRunner $loginRunner -Repair

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'authentication_failed'
        $result.authenticationAction | Should Be 'failed'
        $script:probeCalls | Should Be 1
        $script:loginCalls | Should Be 1
    }
}

Describe 'AI CLI process startup' {
    # Scenario: A command does not exist and Windows returns a localized startup exception.
    # Purpose: Classify missing executables without depending on exception message language.
    It 'T010_marks_an_unresolvable_command_as_command_not_found' {
        # Given
        $missingCommand = 'ai-cli-command-that-does-not-exist'

        # When
        $result = Invoke-CapturedProcess -Command $missingCommand -Arguments @('--version') -TimeoutSeconds 5

        # Then
        $result.started | Should Be $false
        $result.commandNotFound | Should Be $true
        (Classify-ProbeFailure -ProcessResult $result).reason | Should Be 'command_not_found'
    }

    # Scenario: A Windows provider installs a batch shim instead of a native executable.
    # Purpose: Execute official .bat/.cmd entry points without adding a happy-path command lookup.
    It 'T020_executes_a_batch_shim_after_direct_process_start_fails' {
        # Given
        $batchPath = Join-Path $TestDrive 'provider-shim.bat'
        [System.IO.File]::WriteAllText(
            $batchPath,
            "@echo off`r`necho %~1`r`n",
            [System.Text.Encoding]::ASCII
        )

        $previousPath = $env:Path
        try {
            $env:Path = "$TestDrive;$previousPath"

            # When
            $result = Invoke-CapturedProcess -Command 'provider-shim' -Arguments @('AI_CLI_BATCH_OK') -TimeoutSeconds 10
        }
        finally {
            $env:Path = $previousPath
        }

        # Then
        $result.started | Should Be $true
        $result.exitCode | Should Be 0
        $result.stdout.Trim() | Should Be 'AI_CLI_BATCH_OK'
    }
}

Describe 'AI CLI operational logging' {
    # Scenario: A guarded failure contains nested usage data and raw provider output.
    # Purpose: Persist the required operational fields while excluding prompts and provider content.
    It 'T010_logs_nested_usage_fields_without_raw_provider_content' {
        # Given
        $repositoryRoot = Join-Path $TestDrive 'logging-repository'
        New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
        $entry = [pscustomobject]@{
            provider = 'agy'
            success = $false
            reason = 'resource_hard_limit_reached'
            warning = $null
            usage = [pscustomobject]@{
                known = $true
                usedPercent = 90
                hardLimitPercent = 90
            }
            result = 'private-prompt-content'
        }

        # When
        Write-AiEnvironmentLog -RepositoryRoot $repositoryRoot -Entry $entry
        $logPath = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.ai\logs') -Filter '*.jsonl' | Select-Object -First 1
        $rawLog = Get-Content -Raw -LiteralPath $logPath.FullName
        $log = $rawLog | ConvertFrom-Json

        # Then
        $log.usageKnown | Should Be $true
        $log.usedPercent | Should Be 90
        $log.hardLimitPercent | Should Be 90
        $rawLog | Should Not Match 'private-prompt-content'
        ($log.PSObject.Properties.Name -contains 'result') | Should Be $false
    }
}

Describe 'Provider adapter contracts' {
    # Scenario: Provider adapters expose the verified primary commands and Spark model identifier.
    # Purpose: Keep provider-specific reality out of the shared policy layer.
    It 'T010_defines_verified_primary_probe_commands_per_provider' {
        # Given / When
        $codex = Get-ProviderAdapter -ResourceName 'codexMain'
        $spark = Get-ProviderAdapter -ResourceName 'codexSpark'
        $copilot = Get-ProviderAdapter -ResourceName 'copilotPersonal'
        $agy = Get-ProviderAdapter -ResourceName 'agy'
        $junie = Get-ProviderAdapter -ResourceName 'junie'

        # Then
        $codex.primaryProbe.command | Should Be 'codex'
        ($codex.primaryProbe.arguments -join ' ') | Should Be 'login status'
        $spark.model | Should Be 'gpt-5.3-codex-spark'
        $copilot.primaryProbe.mode | Should Be 'execution'
        $agy.primaryProbe.command | Should Be 'agy'
        ($agy.primaryProbe.arguments -join ' ') | Should Be 'models'
        $junie.primaryProbe.mode | Should Be 'execution'
    }

    # Scenario: Personal and company Copilot profiles resolve from the same local state root.
    # Purpose: Prevent the two accounts from sharing one mutable COPILOT_HOME session.
    It 'T020_isolates_copilot_personal_and_company_profile_state' {
        # Given
        $stateRoot = Join-Path $TestDrive 'state'

        # When
        $personal = Get-ResourceEnvironment -ResourceName 'copilotPersonal' -StateRoot $stateRoot
        $company = Get-ResourceEnvironment -ResourceName 'copilotCompany' -StateRoot $stateRoot

        # Then
        $personal.COPILOT_HOME | Should Not Be $company.COPILOT_HOME
        $personal.COPILOT_HOME | Should Match 'personal$'
        $company.COPILOT_HOME | Should Match 'company$'
        $personal.ContainsKey('COPILOT_GITHUB_TOKEN') | Should Be $false
        $company.ContainsKey('COPILOT_GITHUB_TOKEN') | Should Be $false
    }

    # Scenario: Junie is configured with a provider key, a Junie token, or neither.
    # Purpose: Verify consumption mode only when official environment evidence exists.
    It 'T030_reports_junie_consumption_mode_without_exposing_or_guessing_credentials' {
        # Given / When
        $byok = Get-JunieConsumptionMode -Environment @{ JUNIE_OPENAI_API_KEY = 'secret' }
        $jetbrains = Get-JunieConsumptionMode -Environment @{ JUNIE_API_KEY = 'secret' }
        $unknown = Get-JunieConsumptionMode -Environment @{}

        # Then
        $byok.consumptionMode | Should Be 'byok'
        $byok.consumptionModeVerified | Should Be $true
        $jetbrains.consumptionMode | Should Be 'jetbrains-ai'
        $jetbrains.consumptionModeVerified | Should Be $true
        $unknown.consumptionMode | Should Be 'unknown'
        $unknown.consumptionModeVerified | Should Be $false
    }

    # Scenario: Company uses the official stored credential while Personal requires its dedicated token.
    # Purpose: Prevent both logical profiles from silently consuming the same system credential-store account.
    It 'T040_requires_a_dedicated_token_for_the_personal_copilot_profile' {
        # Given
        $configuration = New-TestAiConfiguration
        $personalEnvironment = @{}
        $companyEnvironment = @{}

        # When
        $personal = Resolve-CopilotProfileAuthentication `
            -ResourceName 'copilotPersonal' `
            -ResourceConfig $configuration.resources.copilotPersonal `
            -Environment $personalEnvironment
        $company = Resolve-CopilotProfileAuthentication `
            -ResourceName 'copilotCompany' `
            -ResourceConfig $configuration.resources.copilotCompany `
            -Environment $companyEnvironment
        $personalWithToken = Resolve-CopilotProfileAuthentication `
            -ResourceName 'copilotPersonal' `
            -ResourceConfig $configuration.resources.copilotPersonal `
            -Environment @{ COPILOT_GITHUB_TOKEN = 'test-token-value' }

        # Then
        $personal.ready | Should Be $false
        $personal.reason | Should Be 'authentication_required'
        $company.ready | Should Be $true
        $company.source | Should Be 'stored'
        $personalWithToken.ready | Should Be $true
        $personalWithToken.source | Should Be 'token'
    }
}

Describe 'AI CLI environment installer' {
    # Scenario: The environment layer is installed twice into a clean target repository.
    # Purpose: Ensure installation is repeatable and preserves an existing resource configuration.
    It 'T010_installs_expected_tools_idempotently_without_overwriting_config' {
        # Given
        $targetRoot = Join-Path $TestDrive 'repository'
        New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $configPath = Join-Path $targetRoot '.ai\config.json'
        $customConfig = (Get-Content -Raw -LiteralPath $configPath).Replace('"hardLimitPercent": 90', '"hardLimitPercent": 70')
        [System.IO.File]::WriteAllText($configPath, $customConfig, (New-Object System.Text.UTF8Encoding($false)))

        # When
        Install-AiCliEnvironment -TargetRoot $targetRoot

        # Then
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\ai-usage.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\ai-doctor.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\common\resource-policy.ps1') | Should Be $true
        (Get-Content -Raw -LiteralPath $configPath) | Should Match '"hardLimitPercent": 70'
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.gitignore')) | Should Match '\.ai/logs/'
        (Get-Content -Raw -LiteralPath (Join-Path $targetRoot '.gitignore')) | Should Match '\.ai/usage-state\.json'
    }

    # Scenario: An execution-mode provider has unknown usage while policy is deny.
    # Purpose: Ensure the wrapper hard guard blocks the requested task before any provider process starts.
    It 'T020_blocks_execution_when_unknown_usage_policy_is_deny' {
        # Given
        $targetRoot = Join-Path $TestDrive 'deny-repository'
        New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $configPath = Join-Path $targetRoot '.ai\config.json'
        $configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $configuration.unknownUsagePolicy = 'deny'
        $configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $script:taskCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:taskCalls++
            New-TestProcessResult -StdOut 'task executed'
        }

        # When
        $result = Invoke-GuardedResourceCommand -ResourceName 'copilotCompany' -RepositoryRoot $targetRoot -Arguments @('test') -ProcessRunner $processRunner -NoRepair

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'usage_unknown'
        $script:taskCalls | Should Be 0
    }

    # Scenario: A provider option begins with a dash when a thin wrapper is launched as a PowerShell script.
    # Purpose: Preserve native CLI arguments such as Copilot and Agy -p without binding them as wrapper parameters.
    It 'T030_forwards_provider_options_without_powershell_parameter_binding_conflicts' {
        # Given
        $targetRoot = Join-Path $TestDrive 'argument-forwarding-repository'
        New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $configPath = Join-Path $targetRoot '.ai\config.json'
        $configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $configuration.resources.copilotCompany.enabled = $false
        [System.IO.File]::WriteAllText(
            $configPath,
            ($configuration | ConvertTo-Json -Depth 10),
            [System.Text.UTF8Encoding]::new($false)
        )
        $wrapperPath = Join-Path $targetRoot 'tools\copilot-company.ps1'

        # When
        $process = Invoke-CapturedProcess `
            -Command (Join-Path $PSHOME 'pwsh.exe') `
            -Arguments @('-NoProfile', '-File', $wrapperPath, '-NoRepair', '-p', 'test prompt', '--allow-all-tools') `
            -TimeoutSeconds 30

        # Then
        [string]::IsNullOrWhiteSpace($process.stdout) | Should Be $false
        $process.stderr | Should Not Match 'parameter name.+ambiguous'
        $payload = $process.stdout | ConvertFrom-Json
        $payload.success | Should Be $false
        $payload.reason | Should Be 'resource_disabled'
    }
}
