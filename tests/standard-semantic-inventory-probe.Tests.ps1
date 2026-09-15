Describe 'Installed semantic scanner inventory probe' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'standard-semantic-assertions.ps1')
        $pythonApplications = @(Get-Command -Name python -CommandType Application -ErrorAction Stop)
        $script:Python = [string]$pythonApplications[0].Source
        $script:UnitFile = Join-Path $PSScriptRoot 'semantic-inventory-probe-unit.py'
    }

    # Scenario: The scanner probe's version, registered/wired set and output-boundary unit cases run in an ordinary Python host.
    # Purpose: Include the fail-closed inventory bridge in the central Pester regression without requiring provider credentials.
    It 'InterT10_runs_semantic_inventory_probe_contract_without_an_llm' {
        $result = @(& $script:Python -B $script:UnitFile 2>&1)
        $LASTEXITCODE | Assert-SemanticEqual -Expected 0
        ($result -join "`n") | Assert-SemanticMatch -Pattern 'Ran 5 tests'
        ($result -join "`n") | Assert-SemanticMatch -Pattern '(?m)^OK$'
    }
}
