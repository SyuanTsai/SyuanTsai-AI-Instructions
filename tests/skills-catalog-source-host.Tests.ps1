$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1') -Force

Describe 'Skills Catalog source host contract' {
    It 'UnitT10_rejects_non_GitHub_external_sources_before_retrieval' {
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\skills-catalog.json') | ConvertFrom-Json
        @($catalog.sources)[0].repository = 'https://example.org/acme/skills.git'
        $path = Join-Path $TestDrive 'non-github-catalog.json'
        [System.IO.File]::WriteAllText($path,(($catalog | ConvertTo-Json -Depth 30) + "`n"),(New-Object System.Text.UTF8Encoding($false)))

        $thrown = $false
        $message = $null
        try { Test-SkillsCatalogDocument -CatalogPath $path | Out-Null }
        catch { $thrown = $true; $message = $_.Exception.Message }

        $thrown | Should Be $true
        $message | Should Match 'github.com owner/repository'
    }
}
