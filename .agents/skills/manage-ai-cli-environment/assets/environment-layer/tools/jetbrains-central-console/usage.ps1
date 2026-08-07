Set-StrictMode -Version Latest

function ConvertFrom-JetBrainsUsageNumber {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $Column
    )

    $number = 0.0
    $text = [string] $Value
    $styles = [Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowExponent
    if ([string]::IsNullOrWhiteSpace($text) -or
        (-not [double]::TryParse($text, $styles, [Globalization.CultureInfo]::InvariantCulture, [ref] $number) -and
         -not [double]::TryParse($text, $styles, [Globalization.CultureInfo]::CurrentCulture, [ref] $number))) {
        throw "JetBrains Central Console column '$Column' must contain numeric values."
    }
    if ($number -lt 0) {
        throw "JetBrains Central Console column '$Column' cannot contain negative values."
    }
    return $number
}

function Import-JetBrainsCentralConsoleUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $UsedColumn,

        [string] $LimitColumn,

        [string] $RemainingColumn,

        [string] $UnitType = 'AI Credits',

        [string] $Scope = 'monthly'
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "JetBrains Central Console CSV was not found: $resolvedPath"
    }

    $rows = @(Import-Csv -LiteralPath $resolvedPath)
    if ($rows.Count -eq 0) {
        throw 'JetBrains Central Console CSV must contain at least one data row.'
    }
    $columns = @($rows[0].PSObject.Properties.Name)
    foreach ($column in @($UsedColumn, $LimitColumn, $RemainingColumn)) {
        if (-not [string]::IsNullOrWhiteSpace($column) -and $column -notin $columns) {
            throw "JetBrains Central Console CSV column '$column' was not found."
        }
    }

    $usedQuantity = [double] 0
    $limitQuantity = if ([string]::IsNullOrWhiteSpace($LimitColumn)) { $null } else { [double] 0 }
    $remainingQuantity = if ([string]::IsNullOrWhiteSpace($RemainingColumn)) { $null } else { [double] 0 }
    foreach ($row in $rows) {
        $usedQuantity += ConvertFrom-JetBrainsUsageNumber -Value $row.$UsedColumn -Column $UsedColumn
        if ($null -ne $limitQuantity) {
            $limitQuantity += ConvertFrom-JetBrainsUsageNumber -Value $row.$LimitColumn -Column $LimitColumn
        }
        if ($null -ne $remainingQuantity) {
            $remainingQuantity += ConvertFrom-JetBrainsUsageNumber -Value $row.$RemainingColumn -Column $RemainingColumn
        }
    }

    if ($null -eq $limitQuantity -and $null -ne $remainingQuantity) {
        $limitQuantity = $usedQuantity + $remainingQuantity
    }
    if ($null -ne $limitQuantity -and $limitQuantity -le 0) {
        throw 'The aggregate JetBrains Central Console quota must be greater than zero.'
    }
    if ($null -eq $remainingQuantity -and $null -ne $limitQuantity) {
        $remainingQuantity = $limitQuantity - $usedQuantity
    }

    $percentageKnown = $null -ne $limitQuantity
    $rawUsage = [pscustomobject]@{
        source = 'jetbrains-central-console-csv'
        queriedAt = (Get-Date).ToString('o')
        known = $percentageKnown
        usageAmountKnown = $true
        limitAmountKnown = $percentageKnown
        remainingAmountKnown = $null -ne $remainingQuantity
        usedPercent = if ($percentageKnown) { [Math]::Round(($usedQuantity / $limitQuantity) * 100, 4) } else { $null }
        remainingPercent = if ($percentageKnown) { [Math]::Round(($remainingQuantity / $limitQuantity) * 100, 4) } else { $null }
        usedQuantity = $usedQuantity
        limitQuantity = $limitQuantity
        remainingQuantity = $remainingQuantity
        unitType = $UnitType
        scope = $Scope
        unlimited = $false
        details = @([pscustomobject]@{ rowCount = $rows.Count })
        reason = if ($percentageKnown) { $null } else { 'limit_unavailable' }
    }

    return ConvertTo-UsageSnapshot `
        -ResourceName 'junie' `
        -Usage $rawUsage `
        -AcquisitionMode 'csv_import'
}
