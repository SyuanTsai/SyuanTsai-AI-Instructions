Describe 'Installed semantic scanner inventory probe' {
    BeforeAll {
        $pythonApplications = @(Get-Command -Name python -CommandType Application -ErrorAction Stop)
        $script:Python = [string]$pythonApplications[0].Source
        $script:UnitFile = Join-Path $PSScriptRoot 'semantic-inventory-probe-unit.py'
    }

    # Scenario: The scanner probe's version, registered/wired set and output-boundary unit cases run in an ordinary Python host.
    # Purpose: Include the fail-closed inventory bridge in the central Pester regression without requiring provider credentials.
    It 'InterT10_runs_semantic_inventory_probe_contract_without_an_llm' {
        $result = @(& $script:Python -B $script:UnitFile 2>&1)
        $LASTEXITCODE | Should -Be 0
        ($result -join "`n") | Should -Match 'Ran 5 tests'
        ($result -join "`n") | Should -Match '(?m)^OK$'
    }
}
