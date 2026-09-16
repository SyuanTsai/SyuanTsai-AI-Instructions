Describe 'Installed semantic scanner inventory probe' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'standard-semantic-assertions.ps1')
        $approvedPython = [Environment]::GetEnvironmentVariable('STANDARD_AUTHORITY_PYTHON','Process')
        if ([string]::IsNullOrWhiteSpace($approvedPython)) {
            $pythonApplications = @(Get-Command -Name python -CommandType Application -ErrorAction Stop)
            $approvedPython = [string]$pythonApplications[0].Source
        }
        $script:Python = [IO.Path]::GetFullPath($approvedPython)
        if (-not (Test-Path -LiteralPath $script:Python -PathType Leaf)) { throw 'Approved semantic test Python is unavailable.' }
        $script:UnitFile = Join-Path $PSScriptRoot 'semantic-inventory-probe-unit.py'
    }

    # Scenario: The scanner probe's version, registered/wired set and output-boundary unit cases run in an ordinary Python host.
    # Purpose: Include the fail-closed inventory bridge in the central Pester regression without requiring provider credentials.
    It 'InterT10_runs_semantic_inventory_probe_contract_without_an_llm' {
        $result = @(& $script:Python -I -B $script:UnitFile 2>&1)
        $LASTEXITCODE | Assert-SemanticEqual -Expected 0
        ($result -join "`n") | Assert-SemanticMatch -Pattern 'Ran 6 tests'
        ($result -join "`n") | Assert-SemanticMatch -Pattern '(?m)^OK$'
    }
}
