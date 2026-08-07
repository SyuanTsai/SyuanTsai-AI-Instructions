Set-StrictMode -Version Latest

function Write-AiEnvironmentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [psobject] $Entry
    )

    $logDirectory = Join-Path $RepositoryRoot '.ai\logs'
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    $logPath = Join-Path $logDirectory ("{0}.jsonl" -f (Get-Date -Format 'yyyy-MM-dd'))
    $nestedUsage = if ($null -ne $Entry.PSObject.Properties['usage']) { $Entry.usage } else { $null }
    $usageKnown = if ($null -ne $Entry.PSObject.Properties['usageKnown']) {
        $Entry.usageKnown
    }
    elseif ($null -ne $nestedUsage -and $null -ne $nestedUsage.PSObject.Properties['known']) {
        $nestedUsage.known
    }
    else {
        $false
    }
    $usedPercent = if ($null -ne $Entry.PSObject.Properties['usedPercent']) {
        $Entry.usedPercent
    }
    elseif ($null -ne $nestedUsage -and $null -ne $nestedUsage.PSObject.Properties['usedPercent']) {
        $nestedUsage.usedPercent
    }
    else {
        $null
    }
    $hardLimitPercent = if ($null -ne $Entry.PSObject.Properties['hardLimitPercent']) {
        $Entry.hardLimitPercent
    }
    elseif ($null -ne $nestedUsage -and $null -ne $nestedUsage.PSObject.Properties['hardLimitPercent']) {
        $nestedUsage.hardLimitPercent
    }
    else {
        $null
    }

    # Only an explicit allowlist of operational fields is persisted. Raw command
    # output, arguments, environment variables, prompts, and credentials are excluded.
    $safe = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        provider = $Entry.provider
        probeResult = if ($null -ne $Entry.PSObject.Properties['probeResult']) { $Entry.probeResult } else { $null }
        usageKnown = $usageKnown
        usedPercent = $usedPercent
        hardLimitPercent = $hardLimitPercent
        bootstrapAction = if ($null -ne $Entry.PSObject.Properties['bootstrapAction']) { $Entry.bootstrapAction } else { $null }
        authenticationAction = if ($null -ne $Entry.PSObject.Properties['authenticationAction']) { $Entry.authenticationAction } else { $null }
        executionResult = if ($null -ne $Entry.PSObject.Properties['executionResult']) { $Entry.executionResult } else { $null }
        errorReason = if ($null -ne $Entry.PSObject.Properties['reason']) { $Entry.reason } else { $null }
        durationMs = if ($null -ne $Entry.PSObject.Properties['durationMs']) { $Entry.durationMs } else { $null }
    }

    Add-Content -LiteralPath $logPath -Value ($safe | ConvertTo-Json -Compress -Depth 5) -Encoding utf8
}
