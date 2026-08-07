Set-StrictMode -Version Latest

$script:GlobalAiResourceNames = @(
    'codexMain',
    'codexSpark',
    'copilotPersonal',
    'copilotCompany',
    'agy',
    'junie'
)

function Resolve-GlobalAiResourceGuardRoot {
    [CmdletBinding()]
    param(
        [string] $GlobalRoot,

        [scriptblock] $EnvironmentReader = {
            param($Name, $Target)
            [Environment]::GetEnvironmentVariable($Name, $Target)
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($GlobalRoot)) {
        return [IO.Path]::GetFullPath($GlobalRoot)
    }

    foreach ($target in @([EnvironmentVariableTarget]::Process, [EnvironmentVariableTarget]::User)) {
        $configuredRoot = & $EnvironmentReader 'AI_RESOURCE_GUARD_HOME' $target
        if (-not [string]::IsNullOrWhiteSpace([string] $configuredRoot)) {
            return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string] $configuredRoot))
        }
    }

    $localApplicationData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        throw 'LocalApplicationData is unavailable; set AI_RESOURCE_GUARD_HOME explicitly.'
    }
    return Join-Path $localApplicationData 'ai-resource-guard'
}

function Get-GlobalResourceStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot
    )

    return Join-Path $GlobalRoot "state\resources\$ResourceName.json"
}
