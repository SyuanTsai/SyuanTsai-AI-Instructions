$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:ToolsRoot = Join-Path $script:SkillRoot 'assets\environment-layer\tools'
$script:CommonImportScript = Join-Path $script:ToolsRoot 'common\import.ps1'

. $script:CommonImportScript

Describe 'Copilot Personal provider tool structure' {
    # Scenario: Copilot shares provider logic while Personal owns explicit entry points.
    # Purpose: Keep the user-facing workflow aligned with Codex without duplicating provider internals.
    It 'T010_exposes_personal_login_usage_and_doctor_entry_points' {
        # Given / When
        $sharedFiles = @('credentials.ps1', 'usage.ps1')
        $personalFiles = @('login.ps1', 'get-usage.ps1', 'doctor.ps1')

        # Then
        foreach ($file in $sharedFiles) {
            Test-Path -LiteralPath (Join-Path $script:ToolsRoot "copilot\$file") -PathType Leaf | Should Be $true
        }
        foreach ($file in $personalFiles) {
            Test-Path -LiteralPath (Join-Path $script:ToolsRoot "copilot\personal\$file") -PathType Leaf | Should Be $true
        }
    }
}

Describe 'Copilot Personal credential isolation' {
    # Scenario: Personal and Company credentials coexist on one Windows user account.
    # Purpose: Use only the dedicated Personal credential and prevent fallback to inherited GitHub tokens.
    It 'T010_maps_only_the_personal_credential_into_the_child_environment' {
        # Given
        $credentialReader = {
            param($TargetName)
            if ($TargetName -eq 'ai-cli/copilot/personal') { return 'personal-test-token' }
            return $null
        }
        $environmentReader = {
            param($Name, $Target)
            if ($Name -eq 'GH_TOKEN') { return 'company-fallback-token' }
            return $null
        }

        # When
        $environment = Get-ResourceEnvironment `
            -ResourceName 'copilotPersonal' `
            -StateRoot (Join-Path $TestDrive 'state') `
            -EnvironmentReader $environmentReader `
            -CredentialReader $credentialReader

        # Then
        $environment.COPILOT_GITHUB_TOKEN | Should Be 'personal-test-token'
        $environment.ContainsKey('GH_TOKEN') | Should Be $true
        $environment.GH_TOKEN | Should Be $null
        $environment.ContainsKey('GITHUB_TOKEN') | Should Be $true
        $environment.GITHUB_TOKEN | Should Be $null
    }
}

Describe 'Copilot Personal usage conversion' {
    # Scenario: The official user billing endpoint returns current-month premium-request quantities.
    # Purpose: Preserve known usage amounts without inventing a plan denominator or percentage.
    It 'T010_returns_official_usage_amount_with_an_unknown_limit' {
        # Given
        $response = [pscustomobject]@{
            timePeriod = [pscustomobject]@{ year = 2026; month = 8 }
            usageItems = @(
                [pscustomobject]@{ product = 'Copilot'; sku = 'Copilot Premium Request'; model = 'gpt-test'; unitType = 'requests'; grossQuantity = 20; netQuantity = 0 },
                [pscustomobject]@{ product = 'Copilot'; sku = 'Copilot Premium Request'; model = 'claude-test'; unitType = 'requests'; grossQuantity = 5; netQuantity = 0 }
            )
        }

        # When
        $usage = ConvertFrom-CopilotPersonalBillingUsage -Response $response

        # Then
        $usage.provider | Should Be 'copilotPersonal'
        $usage.source | Should Be 'github-billing-user'
        $usage.usageAmountKnown | Should Be $true
        $usage.usedQuantity | Should Be 25
        $usage.limitQuantity | Should Be $null
        $usage.known | Should Be $false
        $usage.usedPercent | Should Be $null
        $usage.reason | Should Be 'limit_unavailable'
    }

    # Scenario: The user explicitly opts in to the non-public Copilot quota endpoint.
    # Purpose: Normalize a finite premium-request meter without exposing account metadata.
    It 'T020_normalizes_private_quota_only_when_explicitly_selected' {
        # Given
        $response = [pscustomobject]@{
            login = 'private-user-name'
            quota_snapshots = [pscustomobject]@{
                premium_interactions = [pscustomobject]@{
                    entitlement = 300
                    remaining = 210
                    percent_remaining = 70
                    unlimited = $false
                    quota_id = 'premium_interactions'
                }
            }
        }
        $script:officialCalls = 0
        $script:privateCalls = 0
        $officialRunner = { param($Token) $script:officialCalls++; throw 'official runner should not execute' }
        $privateRunner = { param($Token) $script:privateCalls++; return $response }

        # When
        $usage = Invoke-CopilotPersonalUsageSnapshot `
            -Token 'private-test-token' `
            -PrivateEndpoint `
            -OfficialRunner $officialRunner `
            -PrivateRunner $privateRunner

        # Then
        $script:officialCalls | Should Be 0
        $script:privateCalls | Should Be 1
        $usage.source | Should Be 'github-copilot-private'
        $usage.known | Should Be $true
        $usage.usedPercent | Should Be 30
        $usage.remainingPercent | Should Be 70
        $usage.usedQuantity | Should Be 90
        $usage.limitQuantity | Should Be 300
        ($usage | ConvertTo-Json -Depth 10) | Should Not Match 'private-user-name|private-test-token|quota_id'
    }

    # Scenario: GitHub rejects a token or returns an incompatible schema.
    # Purpose: Return safe UNKNOWN state without leaking the credential or raw provider error.
    It 'T030_returns_safe_unknown_without_leaking_provider_content' {
        # Given
        $runner = { param($Token) throw "request failed with Bearer $Token" }

        # When
        $usage = Invoke-CopilotPersonalUsageSnapshot `
            -Token 'secret-personal-token' `
            -OfficialRunner $runner

        # Then
        $usage.known | Should Be $false
        $usage.reason | Should Be 'usage_query_failed'
        ($usage | ConvertTo-Json -Depth 10) | Should Not Match 'secret-personal-token|request failed|Bearer '
    }
}
