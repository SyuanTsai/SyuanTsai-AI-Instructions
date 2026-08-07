Set-StrictMode -Version Latest

function Read-GlobalResourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot
    )

    $statePath = Get-GlobalResourceStatePath -ResourceName $ResourceName -GlobalRoot $GlobalRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $statePath -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'resource_state_invalid'
    }
}

function Write-GlobalResourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('codexMain', 'codexSpark', 'copilotPersonal', 'copilotCompany', 'agy', 'junie')]
        [string] $ResourceName,

        [Parameter(Mandatory = $true)]
        [string] $GlobalRoot,

        [Parameter(Mandatory = $true)]
        [psobject] $State
    )

    $statePath = Get-GlobalResourceStatePath -ResourceName $ResourceName -GlobalRoot $GlobalRoot
    $stateDirectory = Split-Path -Parent $statePath
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    $temporaryPath = Join-Path $stateDirectory "$ResourceName.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($State | ConvertTo-Json -Depth 20),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $statePath
}
