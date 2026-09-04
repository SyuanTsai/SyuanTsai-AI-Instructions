Describe 'Repository licensing scope' {
    BeforeAll {
        $script:LicensingRoot = Split-Path -Parent $PSScriptRoot
        $script:ExcludedLicensePaths = @(
            '.gitignore',
            'docs/plans/ai-quota-observability-mcp/discussion-record.md',
            'docs/plans/ai-quota-observability-mcp/handoff.md',
            'docs/plans/ai-quota-routing/discussion-record.md',
            'docs/plans/ai-quota-routing/handoff.md',
            'docs/plans/felo-ai-usage/discussion-record.md',
            'docs/plans/felo-ai-usage/handoff.md',
            'docs/plans/guide-agent-cli-installation/installation-reference.md'
        )

        function Get-LicensingText {
            param([string] $RelativePath)
            return (Get-Content -LiteralPath (Join-Path $script:LicensingRoot $RelativePath) -Raw -Encoding UTF8).Replace("`r`n", "`n")
        }

        function Assert-LicensingInventory {
            param($Scope, [string[]] $ExpectedPaths)
            if ($null -eq $Scope -or ($Scope.schemaVersion -isnot [int] -and $Scope.schemaVersion -isnot [long]) -or
                $Scope.schemaVersion -cne 1 -or $Scope.files -isnot [array]) {
                throw 'Invalid licensing scope schema.'
            }
            if ((@($Scope.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'files,schemaVersion,scope,unlistedFiles') {
                throw 'Unexpected licensing scope fields.'
            }
            foreach ($field in @('scope','unlistedFiles')) {
                if ($Scope.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Scope.$field)) {
                    throw 'Missing licensing boundary text.'
                }
            }
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($entry in $Scope.files) {
                if ((@($entry.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'license,path' -or
                    $entry.path -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.path) -or
                    $entry.license -isnot [string] -or @('Apache-2.0','NOASSERTION') -cnotcontains $entry.license) {
                    throw 'Invalid file licensing entry.'
                }
                if (-not $seen.Add($entry.path)) { throw 'Duplicate licensing path.' }
                if ($ExpectedPaths -cnotcontains $entry.path) { throw 'Untracked or incorrectly cased licensing path.' }
                $expectedLicense = if ($script:ExcludedLicensePaths -ccontains $entry.path) { 'NOASSERTION' } else { 'Apache-2.0' }
                if ($entry.license -cne $expectedLicense) { throw 'Unexpected licensing classification.' }
            }
            if ($seen.Count -ne $ExpectedPaths.Count) { throw 'Tracked file missing from licensing scope.' }
        }

        function Get-LicenseDigest {
            param([string] $Text)
            $normalized = $Text.Replace("`r`n", "`n").TrimEnd() + "`n"
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant()
            }
            finally { $sha.Dispose() }
        }
    }

    # Scenario: A tracked file is added, removed, or reclassified in a licensing change.
    # Purpose: Require an exact per-file grant/exclusion inventory rather than silently licensing a directory.
    It 'InterT10_covers_every_tracked_file_with_the_intended_classification' {
        $tracked = @(& git -C $script:LicensingRoot ls-files)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { throw 'Cannot read tracked inventory.' }
        $scope = Get-LicensingText 'licensing-scope.json' | ConvertFrom-Json
        Assert-LicensingInventory -Scope $scope -ExpectedPaths $tracked
        foreach ($path in $tracked) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:LicensingRoot $path) -PathType Leaf)) {
                throw "Missing tracked file: $path"
            }
        }
    }

    # Scenario: A scope edit omits a file, duplicates a path, changes a grant, or introduces an unknown schema.
    # Purpose: Verify that the inventory guard actually rejects representative licensing mistakes.
    It 'UnitT20_rejects_missing_duplicate_unknown_and_misclassified_entries' {
        $source = Get-LicensingText 'licensing-scope.json'
        $baseline = $source | ConvertFrom-Json
        $paths = @($baseline.files.path)
        Assert-LicensingInventory -Scope $baseline -ExpectedPaths $paths
        $mutations = @(
            { param($s) $s.files = @($s.files | Select-Object -Skip 1) },
            { param($s) $s.files = @($s.files) + @($s.files[0]) },
            { param($s) $s.files[0].path = '../outside.txt' },
            { param($s) $s.files[0].license = 'MIT' },
            { param($s) ($s.files | Where-Object path -eq '.gitignore').license = 'Apache-2.0' },
            { param($s) $s.schemaVersion = 2 },
            { param($s) $s.schemaVersion = '1' },
            { param($s) $s | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }
        )
        foreach ($mutate in $mutations) {
            $candidate = $source | ConvertFrom-Json
            & $mutate $candidate
            $rejected = $false
            try { Assert-LicensingInventory -Scope $candidate -ExpectedPaths $paths }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'An invalid licensing inventory was accepted.' }
        }
    }

    # Scenario: A license is truncated or a Windows checkout changes its line endings.
    # Purpose: Preserve the full reviewed Apache text without mistaking CRLF conversion for a license change.
    It 'UnitT30_preserves_the_full_license_with_LF_or_CRLF' {
        $text = Get-LicensingText 'LICENSE'
        $expected = 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'
        foreach ($variant in @($text, $text.Replace("`n", "`r`n"))) {
            if ((Get-LicenseDigest $variant) -cne $expected) { throw 'Full Apache license text changed.' }
        }
        if ((Get-LicenseDigest ($text.Substring(0, $text.Length / 2))) -ceq $expected) {
            throw 'Truncated license incorrectly accepted.'
        }
    }

    # Scenario: Public scope prose loses an exclusion or the attribution and local document links disappear.
    # Purpose: Keep the human-readable boundary consistent with the machine-readable file grants.
    It 'InterT40_keeps_exclusions_attribution_and_document_links_consistent' {
        $scopeText = Get-LicensingText 'LICENSE-SCOPE.md'
        $listedPaths = @([regex]::Matches($scopeText, '(?m)^- `([^`]+)`\s*$') | ForEach-Object { $_.Groups[1].Value })
        if ($listedPaths.Count -ne $script:ExcludedLicensePaths.Count -or
            @($listedPaths | Where-Object { $script:ExcludedLicensePaths -cnotcontains $_ }).Count -gt 0 -or
            @($listedPaths | Select-Object -Unique).Count -ne $listedPaths.Count) {
            throw 'Human-readable exclusions differ from the inventory boundary.'
        }
        $notice = Get-LicensingText 'NOTICE'
        if (-not $notice.Contains('SyuanTsai-AI-Instructions') -or -not $notice.Contains('Copyright 2026 SyuanTsai')) {
            throw 'Missing project attribution.'
        }
        foreach ($document in @('README.md','LICENSE-SCOPE.md','PROVENANCE.md','THIRD_PARTY_NOTICES.md')) {
            foreach ($link in [regex]::Matches((Get-LicensingText $document), '\]\(([^)]+)\)')) {
                $target = $link.Groups[1].Value.Split('#')[0]
                if ($target -and $target -notmatch '^https?://' -and
                    -not (Test-Path -LiteralPath (Join-Path $script:LicensingRoot $target))) {
                    throw "Broken document link in $document"
                }
            }
        }
    }
}
