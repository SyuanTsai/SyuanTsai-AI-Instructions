$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\manage-ai-cli-environment'
$script:ToolsRoot = Join-Path $script:SkillRoot 'assets\environment-layer\tools'
$script:CommonImportScript = Join-Path $script:ToolsRoot 'common\import.ps1'

. $script:CommonImportScript

Describe 'JetBrains Central Console CSV usage source' {
    # Scenario: An administrator exports multiple rows with explicit spent and quota columns.
    # Purpose: Produce a machine-readable aggregate without retaining account or user identifiers.
    It 'T010_imports_explicit_usage_and_limit_columns_into_the_common_contract' {
        # Given
        $csvPath = Join-Path $TestDrive 'ai-credits.csv'
        @'
User,AI Credits spent,Monthly quota
person-one@example.test,25,100
person-two@example.test,50,200
'@ | Set-Content -LiteralPath $csvPath -Encoding utf8

        # When
        $usage = Import-JetBrainsCentralConsoleUsage `
            -Path $csvPath `
            -UsedColumn 'AI Credits spent' `
            -LimitColumn 'Monthly quota'

        # Then
        $usage.provider | Should Be 'junie'
        $usage.source | Should Be 'jetbrains-central-console-csv'
        $usage.acquisitionMode | Should Be 'csv_import'
        $usage.machineReadable | Should Be $true
        $usage.known | Should Be $true
        $usage.usageAmountKnown | Should Be $true
        $usage.limitAmountKnown | Should Be $true
        $usage.usedQuantity | Should Be 75
        $usage.limitQuantity | Should Be 300
        $usage.remainingQuantity | Should Be 225
        $usage.usedPercent | Should Be 25
        $usage.details[0].rowCount | Should Be 2
        ($usage | ConvertTo-Json -Depth 10) | Should Not Match 'person-one|person-two'
    }

    # Scenario: The exported data contains consumption but no compatible quota denominator.
    # Purpose: Keep the amount useful while preventing the hard-limit guard from guessing a percentage.
    It 'T020_keeps_percentage_unknown_when_only_usage_amount_is_imported' {
        # Given
        $csvPath = Join-Path $TestDrive 'usage-only.csv'
        @'
Account,Spent
team-a,12.5
team-b,7.5
'@ | Set-Content -LiteralPath $csvPath -Encoding utf8

        # When
        $usage = Import-JetBrainsCentralConsoleUsage `
            -Path $csvPath `
            -UsedColumn 'Spent'

        # Then
        $usage.known | Should Be $false
        $usage.usageAmountKnown | Should Be $true
        $usage.limitAmountKnown | Should Be $false
        $usage.usedQuantity | Should Be 20
        $usage.limitQuantity | Should Be $null
        $usage.usedPercent | Should Be $null
        $usage.reason | Should Be 'limit_unavailable'
    }

    # Scenario: The caller names a column that the export does not contain.
    # Purpose: Fail explicitly instead of silently importing zero usage.
    It 'T030_rejects_missing_or_non_numeric_mapped_columns' {
        # Given
        $missingColumnPath = Join-Path $TestDrive 'missing-column.csv'
        "Spent`n10" | Set-Content -LiteralPath $missingColumnPath -Encoding utf8
        $invalidNumberPath = Join-Path $TestDrive 'invalid-number.csv'
        "Spent`nnot-a-number" | Set-Content -LiteralPath $invalidNumberPath -Encoding utf8

        # When / Then
        { Import-JetBrainsCentralConsoleUsage -Path $missingColumnPath -UsedColumn 'Unknown' } |
            Should Throw "JetBrains Central Console CSV column 'Unknown' was not found."
        { Import-JetBrainsCentralConsoleUsage -Path $invalidNumberPath -UsedColumn 'Spent' } |
            Should Throw "JetBrains Central Console column 'Spent' must contain numeric values."
    }
}
