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
        $script:InstalledProbe = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Inspect-InstalledSemanticScanner.py'
        $script:ResolverPython = [Environment]::GetEnvironmentVariable('STANDARD_AUTHORITY_PYTHON','Process')
        $script:FrozenSkillSpectorVersion = '2.11.2'
    }

    # Scenario: The scanner probe's version, registered/wired set and output-boundary unit cases run in an ordinary Python host.
    # Purpose: Include the fail-closed inventory bridge in the central Pester regression without requiring provider credentials.
    It 'InterT10_runs_semantic_inventory_probe_contract_without_an_llm' {
        $result = @(& $script:Python -I -B $script:UnitFile 2>&1)
        $LASTEXITCODE | Assert-SemanticEqual -Expected 0
        ($result -join "`n") | Assert-SemanticMatch -Pattern 'Ran 6 tests'
        ($result -join "`n") | Assert-SemanticMatch -Pattern '(?m)^OK$'
    }

    # Scenario: The authority gate supplies the resolver's isolated SkillSpector Python.
    # Purpose: Exercise the installed graph/import boundary and frozen version through the
    # actual probe CLI; a pure unit suite cannot detect changed package exports or startup.
    It 'InterT11_invokes_the_installed_scanner_probe_with_the_frozen_resolver_python' -Skip:([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('STANDARD_AUTHORITY_PYTHON','Process'))) {
        $outputPath = Join-Path $TestDrive 'installed-semantic-inventory.json'
        $result = @(& $script:ResolverPython -I -B $script:InstalledProbe `
            --expected-version $script:FrozenSkillSpectorVersion `
            --output-path $outputPath --observe-only 2>&1)
        $LASTEXITCODE | Assert-SemanticEqual -Expected 0
        Test-Path -LiteralPath $outputPath -PathType Leaf | Assert-SemanticTrue

        $summaryText = @($result | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\{.*\}$' } | Select-Object -Last 1)
        $summaryText.Count | Assert-SemanticEqual -Expected 1
        $summary = $summaryText[0] | ConvertFrom-Json
        $summary.scannerReady.GetType().Name | Assert-SemanticEqual -Expected 'Boolean'
        $summary.registeredCount | Assert-SemanticMatch -Pattern '^[0-9]+$'
        $summary.wiredCount | Assert-SemanticMatch -Pattern '^[0-9]+$'

        $probe = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $probe.schemaVersion | Assert-SemanticEqual -Expected 1
        $probe.probeType | Assert-SemanticEqual -Expected 'semantic-analyzer-inventory-probe-v1'
        $probe.installedVersion | Assert-SemanticEqual -Expected $script:FrozenSkillSpectorVersion
        $probe.registeredSemanticAnalyzerIds.Count | Assert-SemanticMatch -Pattern '^[1-9][0-9]*$'
        $probe.scanExecuted | Assert-SemanticFalse
        $probe.analyzerCoverageVerified | Assert-SemanticFalse
        $probe.consentStatus | Assert-SemanticEqual -Expected 'pending'
        $probe.signed | Assert-SemanticFalse
        $probe.releaseEligible | Assert-SemanticFalse
    }
}
