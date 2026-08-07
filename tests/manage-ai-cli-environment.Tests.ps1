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

Describe 'Codex machine-readable usage' {
    # Scenario: A signed-in Codex auth file contains an access token and account identifier.
    # Purpose: Query the read-only usage endpoint with the selected account while never returning credentials.
    It 'T010_reads_local_auth_and_queries_usage_without_exposing_credentials' {
        # Given
        $authPath = Join-Path $TestDrive 'auth.json'
        @{
            tokens = @{
                access_token = 'test-access-token'
                account_id = 'test-account-id'
            }
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $authPath -Encoding utf8
        $script:requestedUri = $null
        $script:requestedHeaders = $null
        $requestRunner = {
            param($Uri, $Headers, $TimeoutSeconds)
            $script:requestedUri = $Uri
            $script:requestedHeaders = $Headers
            return [pscustomobject]@{
                rate_limit = [pscustomobject]@{
                    primary_window = [pscustomobject]@{ used_percent = 25; limit_window_seconds = 18000; reset_after_seconds = 900 }
                    secondary_window = $null
                }
            }
        }

        # When
        $usage = Invoke-CodexUsageProbe `
            -ResourceName 'codexMain' `
            -AuthPath $authPath `
            -RequestRunner $requestRunner

        # Then
        $usage.known | Should Be $true
        $usage.usedPercent | Should Be 25
        $usage.source | Should Be 'chatgpt-wham-usage-private'
        $script:requestedUri | Should Be 'https://chatgpt.com/backend-api/wham/usage'
        $script:requestedHeaders.Authorization | Should Be 'Bearer test-access-token'
        $script:requestedHeaders.'ChatGPT-Account-ID' | Should Be 'test-account-id'
        ($usage | ConvertTo-Json -Depth 8) | Should Not Match 'test-access-token|test-account-id'
    }

    # Scenario: Codex returns current-session and weekly windows with different usage percentages.
    # Purpose: Preserve both windows and guard the resource using the most consumed compatible window.
    It 'T020_normalizes_main_windows_and_uses_the_highest_consumption' {
        # Given
        $response = [pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = 18; limit_window_seconds = 18000; reset_after_seconds = 600 }
                secondary_window = [pscustomobject]@{ used_percent = 36; limit_window_seconds = 604800; reset_at = 1786200000 }
            }
        }

        # When
        $usage = ConvertFrom-CodexUsageResponse -ResourceName 'codexMain' -Response $response

        # Then
        $usage.known | Should Be $true
        $usage.usedPercent | Should Be 36
        @($usage.details).Count | Should Be 2
        @($usage.details | Where-Object { $_.scope -eq 'session' -and $_.remainingPercent -eq 82 }).Count | Should Be 1
        @($usage.details | Where-Object { $_.scope -eq 'weekly' -and $_.usedPercent -eq 36 }).Count | Should Be 1
    }

    # Scenario: Codex returns a separate additional rate-limit meter for Spark.
    # Purpose: Keep Spark independent from Main and calculate its guard percentage only from the Spark meter.
    It 'T030_uses_only_the_spark_additional_rate_limit' {
        # Given
        $response = [pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = 92; limit_window_seconds = 18000 }
                secondary_window = [pscustomobject]@{ used_percent = 88; limit_window_seconds = 604800 }
            }
            additional_rate_limits = @(
                [pscustomobject]@{
                    limit_name = 'codex_spark'
                    display_name = 'GPT-5.3-Codex-Spark'
                    rate_limit = [pscustomobject]@{
                        primary_window = [pscustomobject]@{ used_percent = 40; limit_window_seconds = 18000 }
                        secondary_window = [pscustomobject]@{ used_percent = 60; limit_window_seconds = 604800 }
                    }
                }
            )
        }

        # When
        $usage = ConvertFrom-CodexUsageResponse -ResourceName 'codexSpark' -Response $response

        # Then
        $usage.known | Should Be $true
        $usage.usedPercent | Should Be 60
        @($usage.details).Count | Should Be 2
        @($usage.details | Where-Object usedPercent -gt 60).Count | Should Be 0
    }

    # Scenario: The account usage response has Main windows but no distinct Spark meter.
    # Purpose: Never guess Spark consumption from Main when the provider does not expose a compatible meter.
    It 'T040_keeps_spark_unknown_when_its_meter_is_absent' {
        # Given
        $response = [pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = 20; limit_window_seconds = 18000 }
                secondary_window = [pscustomobject]@{ used_percent = 30; limit_window_seconds = 604800 }
            }
        }

        # When
        $usage = ConvertFrom-CodexUsageResponse -ResourceName 'codexSpark' -Response $response

        # Then
        $usage.known | Should Be $false
        $usage.usedPercent | Should Be $null
        $usage.reason | Should Be 'usage_meter_unavailable'
    }

    # Scenario: Local authentication is missing, the request fails, or the provider response is incomplete.
    # Purpose: Degrade to UNKNOWN without throwing, leaking an error body, or treating missing data as zero.
    It 'T050_returns_safe_unknown_results_for_auth_request_and_schema_failures' {
        # Given
        $missingAuthPath = Join-Path $TestDrive 'missing-auth.json'
        $authPath = Join-Path $TestDrive 'valid-auth.json'
        @{ tokens = @{ access_token = 'private-token'; account_id = 'private-account' } } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $authPath -Encoding utf8
        $failingRequest = { throw 'network failed with private-token' }

        # When
        $missingAuth = Invoke-CodexUsageProbe -ResourceName 'codexMain' -AuthPath $missingAuthPath
        $requestFailure = Invoke-CodexUsageProbe -ResourceName 'codexMain' -AuthPath $authPath -RequestRunner $failingRequest
        $invalidResponse = ConvertFrom-CodexUsageResponse -ResourceName 'codexMain' -Response ([pscustomobject]@{})

        # Then
        $missingAuth.reason | Should Be 'authentication_state_unavailable'
        $requestFailure.reason | Should Be 'usage_query_failed'
        $invalidResponse.reason | Should Be 'usage_response_invalid'
        $missingAuth.usedPercent | Should Be $null
        $requestFailure.usedPercent | Should Be $null
        ($requestFailure | ConvertTo-Json -Depth 6) | Should Not Match 'private-token|network failed'
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
        $result.usage.acquisitionMode | Should Be 'official_api'
        $result.usage.machineReadable | Should Be $true
        $result.usage.known | Should Be $false
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

    # Scenario: The Junie CLI is unavailable while a separately exported Central Console snapshot is readable.
    # Purpose: Keep CLI readiness and usage acquisition independent in the returned resource state.
    It 'T060_preserves_independently_acquired_usage_when_cli_readiness_fails' {
        # Given
        $configuration = New-TestAiConfiguration
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            New-TestProcessResult -CommandNotFound $true
        }
        $usageRunner = {
            param($ResourceName, $TimeoutSeconds)
            [pscustomobject]@{
                source = 'jetbrains-central-console-csv'
                acquisitionMode = 'csv_import'
                known = $true
                usedPercent = 40
                remainingPercent = 60
                usedQuantity = 40
                limitQuantity = 100
                remainingQuantity = 60
                unitType = 'AI Credits'
                scope = 'monthly'
                details = @()
                reason = $null
            }
        }

        # When
        $result = Invoke-ResourceAvailability `
            -ResourceName 'junie' `
            -Configuration $configuration `
            -ProcessRunner $processRunner `
            -UsageRunner $usageRunner

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'command_not_found'
        $result.cliReady | Should Be $false
        $result.usageKnown | Should Be $true
        $result.usedPercent | Should Be 40
        $result.usage.acquisitionMode | Should Be 'csv_import'
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

    # Scenario: A newly installed CLI shim exists in a user bin directory that the current process PATH has not loaded yet.
    # Purpose: Start the delegated login window immediately after installation without requiring Codex or PowerShell to restart.
    It 'T025_resolves_a_user_cli_shim_before_the_process_path_refreshes' {
        # Given
        $shimPath = Join-Path $TestDrive 'junie.bat'
        [System.IO.File]::WriteAllText(
            $shimPath,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )

        # When
        $launch = New-UserControlledPowerShellLaunch `
            -Command 'junie' `
            -CommandSearchPaths @($TestDrive) `
            -WorkingDirectory $TestDrive `
            -WindowTitle 'Junie interactive setup'
        $encodedCommandIndex = [Array]::IndexOf($launch.arguments, '-EncodedCommand') + 1
        $decodedCommand = [System.Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($launch.arguments[$encodedCommandIndex])
        )

        # Then
        $decodedCommand | Should Match ([regex]::Escape($shimPath))
    }

    # Scenario: An official login command is exposed as a Windows batch shim.
    # Purpose: Ensure repair can start Junie's interactive login after installation.
    It 'T030_executes_an_interactive_batch_shim_after_command_resolution' {
        # Given
        $batchPath = Join-Path $TestDrive 'provider-login-shim.bat'
        [System.IO.File]::WriteAllText(
            $batchPath,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )

        $previousPath = $env:Path
        try {
            $env:Path = "$TestDrive;$previousPath"

            # When
            $result = Invoke-InteractiveProcess -Command 'provider-login-shim'
        }
        finally {
            $env:Path = $previousPath
        }

        # Then
        $result | Should Be $true
    }

    # Scenario: Interactive CLI onboarding should be handed to a separate visible PowerShell without choosing a browser for the user.
    # Purpose: Keep all account, browser/profile, model, import, and trust decisions inside the user-controlled terminal.
    It 'T040_builds_a_user_controlled_cli_window_without_preselecting_a_browser' {
        # Given
        $cliShim = Join-Path $TestDrive 'cli-test.bat'
        [System.IO.File]::WriteAllText(
            $cliShim,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )

        # When
        $launch = New-UserControlledPowerShellLaunch `
            -Command $cliShim `
            -WorkingDirectory $TestDrive `
            -WindowTitle 'CLI interactive setup' `
            -Instructions @('Make every interactive choice in this window.') `
            -ConfirmationPrompt 'Choose the intended browser context, then press Enter.'
        $encodedCommandIndex = [Array]::IndexOf($launch.arguments, '-EncodedCommand') + 1
        $decodedCommand = [System.Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($launch.arguments[$encodedCommandIndex])
        )

        # Then
        $launch.filePath | Should Match 'pwsh(?:\.exe)?$'
        $launch.windowStyle | Should Be 'Normal'
        $launch.waitForExit | Should Be $false
        $decodedCommand | Should Match ([regex]::Escape($cliShim))
        $decodedCommand | Should Match 'Make every interactive choice in this window\.'
        $decodedCommand | Should Match "Read-Host 'Choose the intended browser context, then press Enter\.'"
        $decodedCommand | Should Match 'Remove-Item Env:TERM -ErrorAction SilentlyContinue'
        $decodedCommand.IndexOf('Remove-Item Env:TERM') | Should BeLessThan $decodedCommand.IndexOf("& '$cliShim'")
        $decodedCommand.IndexOf('Read-Host') | Should BeLessThan $decodedCommand.IndexOf("& '$cliShim'")
        $decodedCommand | Should Not Match 'chrome\.exe|msedge\.exe|firefox\.exe|Start-Process\s+[^\r\n]*https?://'
    }

    # Scenario: A CLI launch descriptor is handed to a process starter.
    # Purpose: Open a normal visible PowerShell asynchronously so the user, rather than the agent, owns the TUI session.
    It 'T050_starts_the_user_controlled_window_without_waiting_for_it_to_close' {
        # Given
        $cliShim = Join-Path $TestDrive 'cli-launch-test.bat'
        [System.IO.File]::WriteAllText(
            $cliShim,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )
        $script:capturedLaunch = $null
        $processStarter = {
            param($Launch)
            $script:capturedLaunch = $Launch
            return [pscustomobject]@{ Id = 4242 }
        }

        # When
        $result = Start-UserControlledPowerShellProcess `
            -Command $cliShim `
            -WorkingDirectory $TestDrive `
            -WindowTitle 'CLI interactive setup' `
            -Instructions @('Make every interactive choice in this window.') `
            -ProcessStarter $processStarter

        # Then
        $result.started | Should Be $true
        $result.processId | Should Be 4242
        $script:capturedLaunch.windowStyle | Should Be 'Normal'
        $script:capturedLaunch.waitForExit | Should Be $false
    }

    # Scenario: A repair flow must verify authentication only after the user closes the delegated terminal.
    # Purpose: Allow one uninterrupted user interaction and resume automated probing without conversational key-by-key handoffs.
    It 'T060_can_wait_for_the_user_controlled_window_before_resuming' {
        # Given
        $cliShim = Join-Path $TestDrive 'cli-wait-test.bat'
        [System.IO.File]::WriteAllText(
            $cliShim,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )
        $script:waitCalls = 0
        $script:fakeProcess = [pscustomobject]@{ Id = 4343; ExitCode = 0 }
        $script:fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            $script:waitCalls++
        }

        # When
        $result = Start-UserControlledPowerShellProcess `
            -Command $cliShim `
            -WorkingDirectory $TestDrive `
            -WindowTitle 'CLI interactive setup' `
            -WaitForExit `
            -ProcessStarter { param($Launch) $script:fakeProcess }

        # Then
        $result.started | Should Be $true
        $result.exitCode | Should Be 0
        $script:waitCalls | Should Be 1
    }

    # Scenario: A selected resource profile requires environment variables inside its delegated PowerShell.
    # Purpose: Preserve account isolation without placing credentials in arguments, output, or repository files.
    It 'T070_sets_child_environment_before_starting_the_user_controlled_cli' {
        # Given
        $cliShim = Join-Path $TestDrive 'cli-environment-test.bat'
        [System.IO.File]::WriteAllText(
            $cliShim,
            "@echo off`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )

        # When
        $launch = New-UserControlledPowerShellLaunch `
            -Command $cliShim `
            -Environment @{ COPILOT_HOME = 'C:\profiles\company' } `
            -WorkingDirectory $TestDrive `
            -WindowTitle 'CLI usage inspection'
        $encodedCommandIndex = [Array]::IndexOf($launch.arguments, '-EncodedCommand') + 1
        $decodedCommand = [System.Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($launch.arguments[$encodedCommandIndex])
        )

        # Then
        $launch.environment.COPILOT_HOME | Should Be 'C:\profiles\company'
        $decodedCommand | Should Not Match 'C:\\profiles\\company'
    }

}

Describe 'AI CLI user-controlled login' {
    # Scenario: Every managed CLI resource requests an interactive login or setup flow.
    # Purpose: Hand all provider choices to one visible user-owned terminal and never select a browser or profile on the user's behalf.
    It 'T010_defines_a_user_controlled_flow_for_every_resource_without_browser_preselection' {
        # Given
        $resourceNames = @('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')

        # When
        $definitions = @($resourceNames | ForEach-Object {
            Get-UserControlledLoginDefinition -ResourceName $_ -RepositoryRoot $TestDrive
        })

        # Then
        $definitions.Count | Should Be 6
        @($definitions | Where-Object { $_.interactionOwner -ne 'user' }).Count | Should Be 0
        @($definitions | Where-Object { $_.preselectBrowser }).Count | Should Be 0
        ($definitions | Where-Object resourceName -eq 'copilotPersonal').command | Should Match 'copilot-personal-token\.ps1$'
        (($definitions | Where-Object resourceName -eq 'copilotCompany').arguments -join ' ') | Should Be 'login --device-code'
    }

    # Scenario: Copilot Company login runs on a desktop that already has a company account in the default browser.
    # Purpose: Keep OAuth in the terminal and let the user open the device URL in any browser/profile instead of auto-opening the existing account.
    It 'T020_uses_device_code_and_waits_in_the_terminal_for_copilot_company' {
        # Given / When
        $definition = Get-UserControlledLoginDefinition `
            -ResourceName 'copilotCompany' `
            -RepositoryRoot $TestDrive

        # Then
        ($definition.arguments -join ' ') | Should Be 'login --device-code'
        $definition.confirmationPrompt | Should Match 'press Enter'
        $definition.preselectBrowser | Should Be $false
    }
}

Describe 'AI CLI user-controlled usage inspection' {
    # Scenario: Every managed resource is inspected through its official CLI in a visible terminal.
    # Purpose: Let the user see provider-owned usage information without scraping terminal output or guessing a quota.
    It 'T010_defines_a_user_controlled_cli_usage_flow_for_every_resource' {
        # Given
        $resourceNames = @('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')

        # When
        $definitions = @($resourceNames | ForEach-Object {
            Get-UserControlledUsageDefinition -ResourceName $_ -RepositoryRoot $TestDrive
        })

        # Then
        $definitions.Count | Should Be 6
        @($definitions | Where-Object { $_.interactionOwner -ne 'user' }).Count | Should Be 0
        @($definitions | Where-Object { $_.machineReadable }).Count | Should Be 0
        (($definitions | Where-Object resourceName -eq 'copilotCompany').instructions -join ' ') | Should Match '/statusline'
        (($definitions | Where-Object resourceName -eq 'codexMain').instructions -join ' ') | Should Match '/usage'
        (($definitions | Where-Object resourceName -eq 'junie').instructions -join ' ') | Should Match '/usage'
        (($definitions | Where-Object resourceName -eq 'agy').instructions -join ' ') | Should Match 'does not expose'
    }

    # Scenario: Copilot Company usage is opened from an isolated Company profile directory.
    # Purpose: Prevent the manual quota check from silently using the Personal resource profile.
    It 'T020_passes_the_selected_copilot_profile_environment_to_the_visible_terminal' {
        # Given
        $stateRoot = Join-Path $TestDrive 'state'
        $script:usageLaunch = $null
        $processStarter = {
            param($Launch)
            $script:usageLaunch = $Launch
            return [pscustomobject]@{ Id = 4545 }
        }

        # When
        $result = Start-UserControlledUsageInspection `
            -ResourceName 'copilotCompany' `
            -RepositoryRoot $TestDrive `
            -StateRoot $stateRoot `
            -ProcessStarter $processStarter
        $encodedCommandIndex = [Array]::IndexOf($script:usageLaunch.arguments, '-EncodedCommand') + 1
        $decodedCommand = [System.Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($script:usageLaunch.arguments[$encodedCommandIndex])
        )

        # Then
        $result.started | Should Be $true
        $result.usageKnown | Should Be $false
        $result.source | Should Be 'provider-cli-user-visible'
        $script:usageLaunch.environment.COPILOT_HOME | Should Be (Join-Path $stateRoot 'copilot\company')
        $decodedCommand | Should Not Match 'COPILOT_HOME'
    }

    # Scenario: Copilot Personal has no dedicated token in process or user environment.
    # Purpose: Never let a manual Personal quota check fall back to the Company account in the system credential store.
    It 'T030_blocks_personal_usage_inspection_when_the_isolated_token_is_missing' {
        # Given
        $script:personalUsageStarts = 0
        $environmentReader = {
            param($Name, $Target)
            return $null
        }

        # When
        $result = Start-UserControlledUsageInspection `
            -ResourceName 'copilotPersonal' `
            -RepositoryRoot $TestDrive `
            -StateRoot (Join-Path $TestDrive 'state') `
            -EnvironmentReader $environmentReader `
            -ProcessStarter { param($Launch) $script:personalUsageStarts++ }

        # Then
        $result.started | Should Be $false
        $result.reason | Should Be 'authentication_required'
        $script:personalUsageStarts | Should Be 0
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

    # Scenario: Every provider exposes how usage can be acquired independently from CLI readiness.
    # Purpose: Prevent the shared flow from assuming that every authenticated CLI has a machine-readable quota.
    It 'T015_declares_usage_acquisition_capabilities_per_provider' {
        # Given / When
        $codex = Get-ProviderAdapter -ResourceName 'codexMain'
        $copilotPersonal = Get-ProviderAdapter -ResourceName 'copilotPersonal'
        $copilotCompany = Get-ProviderAdapter -ResourceName 'copilotCompany'
        $agy = Get-ProviderAdapter -ResourceName 'agy'
        $junie = Get-ProviderAdapter -ResourceName 'junie'

        # Then
        $codex.usageAcquisition.mode | Should Be 'official_api'
        $codex.usageAcquisition.machineReadable | Should Be $true
        $copilotPersonal.usageAcquisition.mode | Should Be 'provider_api'
        $copilotPersonal.usageAcquisition.machineReadable | Should Be $true
        $copilotCompany.usageAcquisition.mode | Should Be 'unsupported'
        $copilotCompany.usageAcquisition.machineReadable | Should Be $false
        $agy.usageAcquisition.mode | Should Be 'unsupported'
        $junie.usageAcquisition.mode | Should Be 'interactive'
        $junie.usageAcquisition.machineReadable | Should Be $false
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

    # Scenario: The delegated Copilot Personal window has just persisted a token to the user environment.
    # Purpose: Let the parent process resume verification without requiring a restart or asking the user to repeat setup.
    It 'T025_reads_a_new_personal_token_from_user_scope_when_process_scope_is_empty' {
        # Given
        $environmentReader = {
            param($Name, $Target)
            if ($Name -eq 'AI_CLI_COPILOT_PERSONAL_TOKEN' -and $Target -eq [EnvironmentVariableTarget]::User) {
                return 'new-user-token'
            }
            return $null
        }

        # When
        $environment = Get-ResourceEnvironment `
            -ResourceName 'copilotPersonal' `
            -StateRoot (Join-Path $TestDrive 'state') `
            -EnvironmentReader $environmentReader

        # Then
        $environment.COPILOT_GITHUB_TOKEN | Should Be 'new-user-token'
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

Describe 'Normalized usage contract' {
    # Scenario: A provider returns a known percentage without quantity fields.
    # Purpose: Expose one stable contract without inventing amount or limit knowledge.
    It 'T010_normalizes_known_percentage_without_inventing_quantities' {
        # Given
        $providerUsage = [pscustomobject]@{
            known = $true
            usedPercent = 35
            remainingPercent = 65
            source = 'codex-app-server'
            scope = 'weekly'
            details = @()
        }

        # When
        $usage = ConvertTo-UsageSnapshot `
            -ResourceName 'codexMain' `
            -Usage $providerUsage `
            -AcquisitionMode 'official_api'

        # Then
        $usage.provider | Should Be 'codexMain'
        $usage.acquisitionMode | Should Be 'official_api'
        $usage.machineReadable | Should Be $true
        $usage.known | Should Be $true
        $usage.usageAmountKnown | Should Be $false
        $usage.limitAmountKnown | Should Be $false
        $usage.remainingAmountKnown | Should Be $false
        $usage.usedPercent | Should Be 35
    }

    # Scenario: Junie exposes usage through a user-controlled interactive command only.
    # Purpose: Preserve a useful action while ensuring unknown usage is not treated as zero or machine-readable.
    It 'T020_normalizes_interactive_usage_as_unknown_with_a_human_action' {
        # Given
        $providerUsage = New-JunieUsageSnapshot

        # When
        $usage = ConvertTo-UsageSnapshot `
            -ResourceName 'junie' `
            -Usage $providerUsage `
            -AcquisitionMode 'interactive'

        # Then
        $usage.acquisitionMode | Should Be 'interactive'
        $usage.machineReadable | Should Be $false
        $usage.known | Should Be $false
        $usage.usedPercent | Should Be $null
        $usage.reason | Should Be 'interactive_usage_only'
        $usage.actions[0].type | Should Be 'human_review'
    }

    # Scenario: Percentage usage is unknown and the configured policy denies unknown usage.
    # Purpose: Keep policy evaluation independent from the provider acquisition mechanism.
    It 'T030_applies_unknown_policy_to_a_normalized_snapshot' {
        # Given
        $usage = ConvertTo-UsageSnapshot `
            -ResourceName 'junie' `
            -Usage (New-JunieUsageSnapshot) `
            -AcquisitionMode 'interactive'

        # When
        $result = Resolve-UsageSnapshotAvailability `
            -UsageSnapshot $usage `
            -HardLimitPercent 100 `
            -UnknownUsagePolicy 'deny'

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'usage_unknown'
        $result.usage.acquisitionMode | Should Be 'interactive'
        $result.usage.known | Should Be $false
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
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\ai-login.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\copilot-personal-token.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\common\resource-policy.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\common\usage-contract.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $targetRoot 'tools\jetbrains-central-console\import-usage.ps1') | Should Be $true
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

    # Scenario: A thin wrapper completes a successful provider task in a fresh PowerShell process.
    # Purpose: Return clean JSON without reading an unset LASTEXITCODE after the PowerShell resource script succeeds.
    It 'T035_returns_clean_wrapper_output_after_a_successful_provider_task' {
        # Given
        $targetRoot = Join-Path $TestDrive 'successful-wrapper-repository'
        $shimRoot = Join-Path $TestDrive 'successful-wrapper-bin'
        New-Item -ItemType Directory -Force -Path $targetRoot, $shimRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $copilotShim = Join-Path $shimRoot 'copilot.bat'
        [System.IO.File]::WriteAllText(
            $copilotShim,
            "@echo off`r`necho COPILOT_WRAPPER_OK`r`nexit /b 0`r`n",
            [System.Text.Encoding]::ASCII
        )
        $wrapperPath = Join-Path $targetRoot 'tools\copilot-company.ps1'
        $previousPath = $env:Path

        try {
            $env:Path = "$shimRoot;$previousPath"

            # When
            $process = Invoke-CapturedProcess `
                -Command (Join-Path $PSHOME 'pwsh.exe') `
                -Arguments @('-NoProfile', '-File', $wrapperPath, '-NoRepair', '-p', 'test prompt', '--allow-all-tools') `
                -TimeoutSeconds 30
        }
        finally {
            $env:Path = $previousPath
        }

        # Then
        $process.exitCode | Should Be 0
        $process.stderr | Should Not Match 'LASTEXITCODE'
        $payload = $process.stdout | ConvertFrom-Json
        $payload.success | Should Be $true
        $payload.result.Trim() | Should Be 'COPILOT_WRAPPER_OK'
    }

    # Scenario: Junie has an interactive JetBrains Account login but no headless credential evidence.
    # Purpose: Explain that subscription login remains interactive-only instead of starting a doomed task.
    It 'T040_requires_a_headless_credential_for_non_interactive_junie_tasks' {
        # Given
        $targetRoot = Join-Path $TestDrive 'junie-auth-repository'
        New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $credentialNames = @(
            'JUNIE_API_KEY',
            'JUNIE_ANTHROPIC_API_KEY',
            'JUNIE_OPENAI_API_KEY',
            'JUNIE_GOOGLE_API_KEY',
            'JUNIE_GROK_API_KEY',
            'JUNIE_OPENROUTER_API_KEY'
        )
        $previousValues = @{}
        foreach ($name in $credentialNames) {
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        $script:taskCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:taskCalls++
            New-TestProcessResult -StdOut 'task executed'
        }

        try {
            # When
            $result = Invoke-GuardedResourceCommand `
                -ResourceName 'junie' `
                -RepositoryRoot $targetRoot `
                -Arguments @('test task') `
                -ProcessRunner $processRunner `
                -NoRepair
        }
        finally {
            foreach ($name in $credentialNames) {
                [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
            }
        }

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'headless_credential_required'
        $result.authenticationAction | Should Be 'interactive_login_or_configure_headless_key'
        $script:taskCalls | Should Be 0
    }

    # Scenario: Junie has explicit API-key evidence and returns an unclassified provider error.
    # Purpose: Do not misreport provider failures as missing interactive authentication.
    It 'T050_preserves_junie_provider_errors_when_api_key_evidence_exists' {
        # Given
        $targetRoot = Join-Path $TestDrive 'junie-provider-error-repository'
        New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
        Install-AiCliEnvironment -TargetRoot $targetRoot
        $previousValue = [Environment]::GetEnvironmentVariable('JUNIE_API_KEY', 'Process')
        [Environment]::SetEnvironmentVariable('JUNIE_API_KEY', 'test-junie-token', 'Process')
        $script:taskCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $TimeoutSeconds)
            $script:taskCalls++
            New-TestProcessResult -ExitCode 1 -StdErr 'Junie failed with the message: 功能錯誤。'
        }

        try {
            # When
            $result = Invoke-GuardedResourceCommand `
                -ResourceName 'junie' `
                -RepositoryRoot $targetRoot `
                -Arguments @('test task') `
                -ProcessRunner $processRunner `
                -NoRepair
        }
        finally {
            [Environment]::SetEnvironmentVariable('JUNIE_API_KEY', $previousValue, 'Process')
        }

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'provider_error'
        $result.authenticationAction | Should BeNullOrEmpty
        $script:taskCalls | Should Be 1
    }
}
