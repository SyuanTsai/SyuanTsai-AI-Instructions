$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:ToolsRoot = Join-Path $script:SkillRoot 'assets\environment-layer\tools'
$script:CodexUsageScript = Join-Path $script:ToolsRoot 'codex\usage.ps1'
$script:CommonImportScript = Join-Path $script:ToolsRoot 'common\import.ps1'

. $script:CommonImportScript

function New-CodexToolTestProcessResult {
    return [pscustomobject]@{
        started = $true
        exitCode = 0
        stdout = 'Logged in using ChatGPT'
        stderr = ''
        commandNotFound = $false
        timedOut = $false
        startError = $null
        durationMs = 1
    }
}

Describe 'Codex provider tool structure' {
    # Scenario: Provider tools are organized by their external data source.
    # Purpose: Keep provider-specific commands and parsers outside the shared tooling layer.
    It 'T010_creates_one_tool_directory_per_provider_source' {
        # Given / When
        $providerDirectories = @('codex', 'copilot', 'antigravity', 'junie')

        # Then
        foreach ($providerDirectory in $providerDirectories) {
            Test-Path -LiteralPath (Join-Path $script:ToolsRoot $providerDirectory) -PathType Container | Should Be $true
        }
    }

    # Scenario: The Codex source is the first provider completed in the new layout.
    # Purpose: Ensure usage, login, and diagnostics have explicit provider-owned entry points.
    It 'T020_exposes_codex_usage_login_and_doctor_entry_points' {
        # Given / When
        $entryPoints = @('get-usage.ps1', 'login.ps1', 'doctor.ps1')

        # Then
        foreach ($entryPoint in $entryPoints) {
            Test-Path -LiteralPath (Join-Path $script:ToolsRoot "codex\$entryPoint") -PathType Leaf | Should Be $true
        }
    }
}

Describe 'Codex app-server usage conversion' {
    # Scenario: Codex returns general and Spark-specific rate-limit snapshots in one response.
    # Purpose: Query the provider once while keeping Main and Spark hard-limit decisions independent.
    It 'T010_normalizes_main_and_spark_from_one_provider_snapshot' {
        # Given
        $result = [pscustomobject]@{
            rateLimits = [pscustomobject]@{
                primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 300; resetsAt = 1786200000 }
                secondary = [pscustomobject]@{ usedPercent = 40; windowDurationMins = 10080; resetsAt = 1786800000 }
                rateLimitReachedType = $null
            }
            rateLimitsByLimitId = [pscustomobject]@{
                codex = [pscustomobject]@{
                    primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 300; resetsAt = 1786200000 }
                    secondary = [pscustomobject]@{ usedPercent = 40; windowDurationMins = 10080; resetsAt = 1786800000 }
                }
                codex_spark = [pscustomobject]@{
                    limitName = 'GPT-5.3-Codex-Spark'
                    primary = [pscustomobject]@{ usedPercent = 10; windowDurationMins = 300; resetsAt = 1786200000 }
                    secondary = [pscustomobject]@{ usedPercent = 60; windowDurationMins = 10080; resetsAt = 1786800000 }
                }
            }
            rateLimitResetCredits = [pscustomobject]@{ availableCount = 2; credits = @() }
        }

        # When
        $snapshot = ConvertFrom-CodexRateLimitsResult -Result $result

        # Then
        $snapshot.provider | Should Be 'codex'
        $snapshot.resources.codexMain.known | Should Be $true
        $snapshot.resources.codexMain.usedPercent | Should Be 40
        $snapshot.resources.codexSpark.known | Should Be $true
        $snapshot.resources.codexSpark.usedPercent | Should Be 60
        @($snapshot.resources.codexMain.details | Where-Object scope -eq 'session').Count | Should Be 1
        @($snapshot.resources.codexMain.details | Where-Object scope -eq 'weekly').Count | Should Be 1
        $snapshot.rateLimitResetCredits.availableCount | Should Be 2
    }

    # Scenario: The provider returns only the general Codex rate-limit meter.
    # Purpose: Never infer Spark usage from Main when a distinct Spark meter is unavailable.
    It 'T020_keeps_spark_unknown_when_no_spark_snapshot_exists' {
        # Given
        $result = [pscustomobject]@{
            rateLimits = [pscustomobject]@{
                primary = [pscustomobject]@{ usedPercent = 20; windowDurationMins = 300 }
                secondary = [pscustomobject]@{ usedPercent = 30; windowDurationMins = 10080 }
            }
            rateLimitsByLimitId = [pscustomobject]@{
                codex = [pscustomobject]@{
                    primary = [pscustomobject]@{ usedPercent = 20; windowDurationMins = 300 }
                    secondary = [pscustomobject]@{ usedPercent = 30; windowDurationMins = 10080 }
                }
            }
        }

        # When
        $snapshot = ConvertFrom-CodexRateLimitsResult -Result $result

        # Then
        $snapshot.resources.codexMain.known | Should Be $true
        $snapshot.resources.codexSpark.known | Should Be $false
        $snapshot.resources.codexSpark.usedPercent | Should Be $null
        $snapshot.resources.codexSpark.reason | Should Be 'usage_meter_unavailable'
    }

    # Scenario: The app-server request succeeds without exposing credential material to the caller.
    # Purpose: Make Codex own token loading and refresh while returning only normalized quota state.
    It 'T030_queries_the_official_app_server_rate_limit_method' {
        # Given
        $script:requestedMethod = $null
        $runner = {
            param($Method, $TimeoutSeconds)
            $script:requestedMethod = $Method
            return [pscustomobject]@{
                rateLimits = [pscustomobject]@{
                    primary = [pscustomobject]@{ usedPercent = 12; windowDurationMins = 300 }
                    secondary = $null
                }
                rateLimitsByLimitId = $null
                rateLimitResetCredits = $null
            }
        }

        # When
        $snapshot = Invoke-CodexUsageSnapshot -AppServerRunner $runner

        # Then
        $script:requestedMethod | Should Be 'account/rateLimits/read'
        $snapshot.source | Should Be 'codex-app-server'
        $snapshot.resources.codexMain.usedPercent | Should Be 12
        ($snapshot | ConvertTo-Json -Depth 12) | Should Not Match 'access_token|Authorization|Bearer '
    }

    # Scenario: Codex is missing, signed out, times out, or rejects the rate-limit method.
    # Purpose: Return an explicit UNKNOWN state without leaking provider stderr or treating failure as zero usage.
    It 'T040_returns_safe_unknown_state_when_the_app_server_query_fails' {
        # Given
        $runner = { throw 'provider failure containing Bearer secret-value' }

        # When
        $snapshot = Invoke-CodexUsageSnapshot -AppServerRunner $runner

        # Then
        $snapshot.resources.codexMain.known | Should Be $false
        $snapshot.resources.codexSpark.known | Should Be $false
        $snapshot.resources.codexMain.reason | Should Be 'usage_query_failed'
        ($snapshot | ConvertTo-Json -Depth 12) | Should Not Match 'secret-value|provider failure'
    }

    # Scenario: npm exposes Codex as a PowerShell shim on Windows.
    # Purpose: Launch the shim through PowerShell instead of treating the script as a native executable.
    It 'T050_launches_a_powershell_cli_shim_through_pwsh' {
        # Given
        $shimPath = Join-Path $TestDrive 'codex.ps1'
        Set-Content -LiteralPath $shimPath -Value "Write-Output 'codex-cli test'"

        # When
        $launch = Resolve-CodexCliLaunch -Command $shimPath

        # Then
        [System.IO.Path]::GetFileName($launch.filePath) | Should Be 'pwsh.exe'
        $launch.arguments[0] | Should Be '-NoProfile'
        $launch.arguments[1] | Should Be '-File'
        $launch.arguments[2] | Should Be ([System.IO.Path]::GetFullPath($shimPath))
    }
}

Describe 'Codex provider policy integration' {
    # Scenario: The Codex provider tool reports usage at or above the resource-specific hard limit.
    # Purpose: Make the existing worker guard consume provider-owned usage without moving Codex parsing back into common code.
    It 'T010_applies_codex_provider_usage_to_the_existing_resource_policy' {
        # Given
        $configuration = [pscustomobject]@{
            schemaVersion = 1
            unknownUsagePolicy = 'warn'
            resources = [pscustomobject]@{
                codexMain = [pscustomobject]@{ enabled = $true; hardLimitPercent = 90 }
                codexSpark = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100; model = 'gpt-5.3-codex-spark' }
                copilotPersonal = [pscustomobject]@{ enabled = $true; hardLimitPercent = 80; authenticationMode = 'token' }
                copilotCompany = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100; authenticationMode = 'stored' }
                agy = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100 }
                junie = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100 }
            }
        }
        $processRunner = { New-CodexToolTestProcessResult }
        $usageRunner = {
            param($ResourceName, $TimeoutSeconds)
            return [pscustomobject]@{
                known = $true
                usedPercent = 90
                source = 'codex-app-server'
                reason = $null
            }
        }

        # When
        $result = Invoke-ResourceAvailability `
            -ResourceName 'codexMain' `
            -Configuration $configuration `
            -ProcessRunner $processRunner `
            -UsageRunner $usageRunner

        # Then
        (Get-ProviderAdapter -ResourceName 'codexMain').usageSource | Should Be 'codex-app-server'
        $result.usageKnown | Should Be $true
        $result.usedPercent | Should Be 90
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_hard_limit_reached'
    }
}
