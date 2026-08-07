$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:GlobalAssetRoot = Join-Path $script:SkillRoot 'assets\global-resource-guard'
$script:GlobalImportPath = Join-Path $script:GlobalAssetRoot 'lib\import.ps1'
$script:GlobalInstallerPath = Join-Path $script:SkillRoot 'scripts\install-global-ai-resource-guard.ps1'

if (Test-Path -LiteralPath $script:GlobalImportPath) {
    . $script:GlobalImportPath
}
if (Test-Path -LiteralPath $script:GlobalInstallerPath) {
    . $script:GlobalInstallerPath
}

function Write-TestGlobalJson {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-TestGlobalGuardConfiguration {
    param(
        [string] $UnknownUsagePolicy = 'warn',
        [int] $StateMaxAgeSeconds = 300
    )

    return [pscustomobject]@{
        schemaVersion = 1
        unknownUsagePolicy = $UnknownUsagePolicy
        stateMaxAgeSeconds = $StateMaxAgeSeconds
        commandTimeoutSeconds = 3600
        resources = [pscustomobject]@{
            codexMain = [pscustomobject]@{ enabled = $true; hardLimitPercent = 90 }
            codexSpark = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100 }
            copilotPersonal = [pscustomobject]@{ enabled = $true; hardLimitPercent = 80; authenticationMode = 'token' }
            copilotCompany = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100; authenticationMode = 'stored' }
            agy = [pscustomobject]@{ enabled = $true; hardLimitPercent = 100 }
            junie = [pscustomobject]@{ enabled = $true; hardLimitPercent = 90 }
        }
    }
}

function New-TestGlobalResourceState {
    param(
        [string] $ResourceName = 'junie',
        [datetime] $UpdatedAt = (Get-Date),
        [bool] $Ready = $true,
        [bool] $UsageKnown = $true,
        [AllowNull()]
        [Nullable[double]] $UsedPercent = 40,
        [string] $ReadinessReason
    )

    return [pscustomobject]@{
        schemaVersion = 1
        resource = $ResourceName
        updatedAt = $UpdatedAt.ToString('o')
        readiness = [pscustomobject]@{
            known = $true
            available = $Ready
            cliReady = $Ready
            authenticationReady = if ($Ready) { $true } else { $false }
            reason = $ReadinessReason
        }
        usage = [pscustomobject]@{
            provider = $ResourceName
            source = 'test-source'
            acquisitionMode = 'provider_api'
            machineReadable = $true
            queriedAt = $UpdatedAt.ToString('o')
            known = $UsageKnown
            usageAmountKnown = $false
            limitAmountKnown = $false
            remainingAmountKnown = $false
            usedPercent = $UsedPercent
            remainingPercent = if ($null -eq $UsedPercent) { $null } else { 100 - $UsedPercent }
            usedQuantity = $null
            limitQuantity = $null
            remainingQuantity = $null
            unitType = $null
            scope = 'monthly'
            unlimited = $false
            details = @()
            reason = if ($UsageKnown) { $null } else { 'limit_unavailable' }
            actions = @()
        }
    }
}

function Initialize-TestGlobalGuard {
    param(
        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot,

        [object] $Configuration = (New-TestGlobalGuardConfiguration),

        [object] $State
    )

    Write-TestGlobalJson -Path (Join-Path $GlobalRoot 'config.json') -Value $Configuration
    if ($null -ne $State) {
        Write-TestGlobalJson `
            -Path (Join-Path $GlobalRoot "state\resources\$($State.resource).json") `
            -Value $State
    }
}

Describe 'Global AI Resource Guard installation' {
    # Scenario: The guard is installed while the current directory is an unrelated Repository.
    # Purpose: Install one user-global copy without writing .ai or tools into the caller Repository.
    It 'T010_installs_global_entry_points_without_modifying_the_current_repository' {
        # Given
        $repositoryRoot = Join-Path $TestDrive 'unrelated-repository'
        $globalRoot = Join-Path $TestDrive 'global-guard'
        New-Item -ItemType Directory -Force -Path $repositoryRoot | Out-Null
        Push-Location -LiteralPath $repositoryRoot
        try {
            # When
            $result = Install-GlobalAiResourceGuard -TargetRoot $globalRoot
        }
        finally {
            Pop-Location
        }

        # Then
        $result.targetRoot | Should Be ([IO.Path]::GetFullPath($globalRoot))
        Test-Path -LiteralPath (Join-Path $globalRoot 'bin\evaluate-resource.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $globalRoot 'bin\execute-resource.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $globalRoot 'bin\refresh-resource-state.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $globalRoot 'provider-tools\common\import.ps1') | Should Be $true
        Test-Path -LiteralPath (Join-Path $repositoryRoot '.ai') | Should Be $false
        Test-Path -LiteralPath (Join-Path $repositoryRoot 'tools') | Should Be $false
    }

    # Scenario: A user has customized global policy before refreshing managed scripts.
    # Purpose: Preserve user policy while allowing an idempotent installation refresh.
    It 'T020_preserves_global_configuration_during_reinstallation' {
        # Given
        $globalRoot = Join-Path $TestDrive 'preserved-global-guard'
        Install-GlobalAiResourceGuard -TargetRoot $globalRoot
        $configPath = Join-Path $globalRoot 'config.json'
        $configuration = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $configuration.resources.junie.hardLimitPercent = 73
        Write-TestGlobalJson -Path $configPath -Value $configuration

        # When
        Install-GlobalAiResourceGuard -TargetRoot $globalRoot -Force

        # Then
        (Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json).resources.junie.hardLimitPercent |
            Should Be 73
    }

    # Scenario: A script invokes the installed evaluator from outside the Global Guard directory.
    # Purpose: Verify the public JSON entry point does not depend on a Repository-local tools or .ai directory.
    It 'T030_runs_the_installed_evaluator_from_an_unrelated_working_directory' {
        # Given
        $globalRoot = Join-Path $TestDrive 'public-entry-point'
        $workingDirectory = Join-Path $TestDrive 'caller-workspace'
        New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null
        $installation = Install-GlobalAiResourceGuard -TargetRoot $globalRoot
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State (New-TestGlobalResourceState)

        # When
        Push-Location -LiteralPath $workingDirectory
        try {
            $result = & $installation.evaluatePath -ResourceName 'junie' -GlobalRoot $globalRoot |
                ConvertFrom-Json
        }
        finally {
            Pop-Location
        }

        # Then
        $result.resource | Should Be 'junie'
        $result.available | Should Be $true
        Test-Path -LiteralPath (Join-Path $workingDirectory '.ai') | Should Be $false
        Test-Path -LiteralPath (Join-Path $workingDirectory 'tools') | Should Be $false
    }
}

Describe 'Global AI Resource evaluation' {
    # Scenario: Junie has a fresh ready state below its configured hard limit.
    # Purpose: Return the minimal structured Can-I-use-this-resource answer.
    It 'T010_allows_a_fresh_ready_resource_below_the_hard_limit' {
        # Given
        $globalRoot = Join-Path $TestDrive 'available'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State (New-TestGlobalResourceState -UsedPercent 40)

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.resource | Should Be 'junie'
        $result.available | Should Be $true
        $result.reason | Should Be $null
        $result.usageKnown | Should Be $true
        $result.usedPercent | Should Be 40
        $result.hardLimitPercent | Should Be 90
    }

    # Scenario: Usage equals the configured hard limit.
    # Purpose: Enforce the inclusive boundary before any provider process can run.
    It 'T020_blocks_usage_equal_to_the_hard_limit' {
        # Given
        $globalRoot = Join-Path $TestDrive 'hard-limit'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State (New-TestGlobalResourceState -UsedPercent 90)

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_hard_limit_reached'
        $result.usedPercent | Should Be 90
    }

    # Scenario: No collector has written state for the requested resource.
    # Purpose: Fail closed instead of collecting usage or assuming zero during evaluation.
    It 'T030_blocks_when_the_requested_resource_state_is_missing' {
        # Given
        $globalRoot = Join-Path $TestDrive 'missing-state'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_state_missing'
        $result.usageKnown | Should Be $false
    }

    # Scenario: The cached state exceeds the configured freshness window.
    # Purpose: Prevent enforcement from relying on arbitrarily old quota data.
    It 'T040_blocks_a_stale_resource_state' {
        # Given
        $globalRoot = Join-Path $TestDrive 'stale-state'
        $now = [datetime]'2026-08-08T12:00:00Z'
        $state = New-TestGlobalResourceState -UpdatedAt $now.AddMinutes(-10)
        Initialize-TestGlobalGuard `
            -GlobalRoot $globalRoot `
            -Configuration (New-TestGlobalGuardConfiguration -StateMaxAgeSeconds 300) `
            -State $state

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot -Now $now

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_state_stale'
        $result.stateAgeSeconds | Should Be 600
    }

    # Scenario: Usage percentage is unavailable and each policy is evaluated for the same state.
    # Purpose: Keep unknown distinct from zero while supporting explicit allow, warn, and deny policies.
    It 'T050_applies_the_selected_unknown_usage_policy' {
        # Given
        $state = New-TestGlobalResourceState -UsageKnown $false -UsedPercent $null
        $results = @{}

        # When
        foreach ($policy in @('allow', 'warn', 'deny')) {
            $globalRoot = Join-Path $TestDrive "unknown-$policy"
            Initialize-TestGlobalGuard `
                -GlobalRoot $globalRoot `
                -Configuration (New-TestGlobalGuardConfiguration -UnknownUsagePolicy $policy) `
                -State $state
            $results[$policy] = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot
        }

        # Then
        $results.allow.available | Should Be $true
        $results.allow.warning | Should Be $null
        $results.warn.available | Should Be $true
        $results.warn.warning | Should Be 'usage_unknown'
        $results.deny.available | Should Be $false
        $results.deny.reason | Should Be 'usage_unknown'
    }

    # Scenario: The collector reports that the requested resource is not ready.
    # Purpose: Reject known CLI or authentication failures before applying usage policy.
    It 'T060_blocks_a_resource_with_known_readiness_failure' {
        # Given
        $globalRoot = Join-Path $TestDrive 'not-ready'
        $state = New-TestGlobalResourceState -Ready $false -ReadinessReason 'authentication_required'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State $state

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'authentication_required'
    }

    # Scenario: Another resource has malformed state while Junie has valid state.
    # Purpose: Prove lazy evaluation reads only the requested resource instead of scanning all resources.
    It 'T070_reads_only_the_requested_resource_state' {
        # Given
        $globalRoot = Join-Path $TestDrive 'lazy-resource'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State (New-TestGlobalResourceState)
        $otherStatePath = Join-Path $globalRoot 'state\resources\codexMain.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $otherStatePath) | Out-Null
        [System.IO.File]::WriteAllText($otherStatePath, '{ invalid json', [System.Text.Encoding]::UTF8)

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $true
        $result.resource | Should Be 'junie'
    }

    # Scenario: A fresh state cannot establish whether the requested CLI is ready.
    # Purpose: Fail closed when resource readiness itself is unknown.
    It 'T080_blocks_when_resource_readiness_is_unknown' {
        # Given
        $globalRoot = Join-Path $TestDrive 'readiness-unknown'
        $state = New-TestGlobalResourceState
        $state.readiness.known = $false
        $state.readiness.available = $false
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State $state

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_readiness_unknown'
    }

    # Scenario: A state claims known usage but contains a non-numeric percentage.
    # Purpose: Return a structured invalid-state rejection instead of throwing or treating malformed usage as zero.
    It 'T090_blocks_a_malformed_known_usage_percentage' {
        # Given
        $globalRoot = Join-Path $TestDrive 'malformed-percentage'
        $state = New-TestGlobalResourceState
        $state.usage.usedPercent = 'not-a-number'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State $state

        # When
        $result = Resolve-GlobalResourceAvailability -ResourceName 'junie' -GlobalRoot $globalRoot

        # Then
        $result.available | Should Be $false
        $result.reason | Should Be 'resource_state_invalid'
    }
}

Describe 'Global AI Resource execution enforcement' {
    # Scenario: Evaluation rejects Junie because no current resource state exists.
    # Purpose: Make the execution layer the enforcement point and never launch the CLI on rejection.
    It 'T010_does_not_start_a_provider_when_evaluation_rejects_it' {
        # Given
        $globalRoot = Join-Path $TestDrive 'execution-blocked'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot
        $script:executionCalls = 0
        $processRunner = {
            param($Command, $Arguments, $Environment, $WorkingDirectory, $TimeoutSeconds)
            $script:executionCalls++
        }

        # When
        $result = Invoke-GlobalResourceExecution `
            -ResourceName 'junie' `
            -GlobalRoot $globalRoot `
            -Arguments @('review this change') `
            -WorkingDirectory $TestDrive `
            -ProcessRunner $processRunner

        # Then
        $result.success | Should Be $false
        $result.executed | Should Be $false
        $result.reason | Should Be 'resource_state_missing'
        $result.exitCode | Should Be $null
        $script:executionCalls | Should Be 0
    }

    # Scenario: Junie is allowed and a caller supplies only resource arguments.
    # Purpose: Execute the fixed provider binary after evaluation without letting callers bypass the resource mapping.
    It 'T020_executes_the_mapped_provider_only_after_successful_evaluation' {
        # Given
        $globalRoot = Join-Path $TestDrive 'execution-allowed'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot -State (New-TestGlobalResourceState)
        $script:capturedExecution = $null
        $runtimeResolver = {
            param($ResourceName, $Root)
            [pscustomobject]@{
                command = 'junie'
                argumentsPrefix = @('--task')
                environment = @{}
            }
        }
        $processRunner = {
            param($Command, $Arguments, $Environment, $WorkingDirectory, $TimeoutSeconds)
            $script:capturedExecution = [pscustomobject]@{
                command = $Command
                arguments = @($Arguments)
                workingDirectory = $WorkingDirectory
            }
            [pscustomobject]@{
                started = $true
                exitCode = 0
                stdout = 'JUNIE_RESULT'
                stderr = ''
                timedOut = $false
                durationMs = 25
            }
        }

        # When
        $result = Invoke-GlobalResourceExecution `
            -ResourceName 'junie' `
            -GlobalRoot $globalRoot `
            -Arguments @('review this change') `
            -WorkingDirectory $TestDrive `
            -ResourceRuntimeResolver $runtimeResolver `
            -ProcessRunner $processRunner

        # Then
        $result.success | Should Be $true
        $result.executed | Should Be $true
        $result.exitCode | Should Be 0
        $result.result | Should Be 'JUNIE_RESULT'
        $script:capturedExecution.command | Should Be 'junie'
        ($script:capturedExecution.arguments -join '|') | Should Be '--task|review this change'
        $script:capturedExecution.workingDirectory | Should Be ([IO.Path]::GetFullPath($TestDrive))
    }

    # Scenario: The installed runtime resolves Codex Spark without executing the provider.
    # Purpose: Keep provider binary and mandatory model selection owned by the Global Guard rather than the caller.
    It 'T030_owns_the_default_provider_command_and_required_prefix' {
        # Given
        $globalRoot = Join-Path $TestDrive 'provider-mapping'
        Install-GlobalAiResourceGuard -TargetRoot $globalRoot

        # When
        $runtime = Get-GlobalResourceRuntime -ResourceName 'codexSpark' -GlobalRoot $globalRoot

        # Then
        $runtime.ready | Should Be $true
        $runtime.command | Should Be 'codex'
        ($runtime.argumentsPrefix -join ' ') | Should Be '-m gpt-5.3-codex-spark'
    }
}

Describe 'Global resource state collector boundary' {
    # Scenario: A collector refreshes only Junie and its provider result contains raw output.
    # Purpose: Atomically persist a sanitized single-resource state without evaluating policy or scanning other resources.
    It 'T010_writes_only_the_requested_sanitized_resource_state' {
        # Given
        $globalRoot = Join-Path $TestDrive 'collector'
        Initialize-TestGlobalGuard -GlobalRoot $globalRoot
        $script:collectedResources = [System.Collections.Generic.List[string]]::new()
        $realityCollector = {
            param($ResourceName, $Root)
            $script:collectedResources.Add($ResourceName)
            [pscustomobject]@{
                provider = $ResourceName
                cliReady = $true
                authenticationReady = $true
                reason = $null
                usage = (New-TestGlobalResourceState -ResourceName $ResourceName).usage
                result = 'private-provider-output'
            }
        }

        # When
        $state = Update-GlobalResourceState `
            -ResourceName 'junie' `
            -GlobalRoot $globalRoot `
            -RealityCollector $realityCollector
        $statePath = Join-Path $globalRoot 'state\resources\junie.json'
        $rawState = Get-Content -Raw -LiteralPath $statePath

        # Then
        $script:collectedResources.Count | Should Be 1
        $script:collectedResources[0] | Should Be 'junie'
        $state.resource | Should Be 'junie'
        Test-Path -LiteralPath $statePath | Should Be $true
        Test-Path -LiteralPath (Join-Path $globalRoot 'state\resources\codexMain.json') | Should Be $false
        $rawState | Should Not Match 'private-provider-output'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '*.tmp').Count | Should Be 0
    }

    # Scenario: The installed refresh entry point uses an explicit Junie CSV usage source.
    # Purpose: Keep provider functions available after the guarded import without depending on caller session state.
    It 'T020_loads_provider_functions_for_the_installed_refresh_entry_point' {
        # Given
        $globalRoot = Join-Path $TestDrive 'installed-collector'
        Install-GlobalAiResourceGuard -TargetRoot $globalRoot
        $providerImportPath = Join-Path $globalRoot 'provider-tools\common\import.ps1'
        $providerFixture = @'
function Import-JetBrainsCentralConsoleUsage {
    param($Path, $UsedColumn, $LimitColumn, $RemainingColumn)
    [pscustomobject]@{
        provider = 'junie'
        source = 'test-central-console'
        acquisitionMode = 'csv_import'
        machineReadable = $true
        queriedAt = (Get-Date).ToString('o')
        known = $true
        usageAmountKnown = $true
        limitAmountKnown = $true
        remainingAmountKnown = $true
        usedPercent = 25
        remainingPercent = 75
        usedQuantity = 25
        limitQuantity = 100
        remainingQuantity = 75
        unitType = 'ai_credits'
        scope = 'junie'
        unlimited = $false
        reason = $null
        actions = @()
    }
}

function Invoke-ResourceAvailability {
    param($ResourceName, $Configuration, $StateRoot, $UsageRunner)
    [pscustomobject]@{
        provider = $ResourceName
        cliReady = $true
        authenticationReady = $true
        reason = $null
        usage = (& $UsageRunner $ResourceName 30)
    }
}
'@
        [IO.File]::WriteAllText($providerImportPath, $providerFixture, [Text.UTF8Encoding]::new($false))
        $csvPath = Join-Path $TestDrive 'usage.csv'
        [IO.File]::WriteAllText($csvPath, "used,limit`n25,100", [Text.UTF8Encoding]::new($false))
        $refreshPath = Join-Path $globalRoot 'bin\refresh-resource-state.ps1'

        # When
        $json = & pwsh -NoProfile -File $refreshPath `
            -ResourceName junie `
            -JunieCentralConsoleCsvPath $csvPath `
            -JunieUsedColumn used `
            -JunieLimitColumn limit
        $exitCode = $LASTEXITCODE
        $state = $json | ConvertFrom-Json

        # Then
        $exitCode | Should Be 0
        $state.resource | Should Be 'junie'
        $state.usage.known | Should Be $true
        $state.usage.usedPercent | Should Be 25
    }
}
