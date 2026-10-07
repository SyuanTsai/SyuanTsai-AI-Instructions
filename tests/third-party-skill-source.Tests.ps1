Describe 'Third party raw Skill source adoption' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../scripts/skills-source-acquisition.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot '../scripts/third-party-skill-source.psm1') -Force -ErrorAction Stop
        function Write-RawFixture { param($Root,$Path,$Text)
            $full = Join-Path $Root $Path
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [IO.File]::WriteAllText($full,$Text,(New-Object Text.UTF8Encoding($false)))
        }
        function Write-RawDescriptor {
            [IO.File]::WriteAllText($descriptorPath,($descriptor | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
        }
        function New-RawFixtureArchive {
            $zip=[IO.Compression.ZipFile]::Open($archivePath,[IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
                    $relative=$file.FullName.Substring($sourceRoot.Length+1).Replace('\','/')
                    $entry=$zip.CreateEntry('snapshot/'+$relative)
                    $stream=$entry.Open()
                    try { $bytes=[IO.File]::ReadAllBytes($file.FullName); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
                }
            } finally { $zip.Dispose() }
        }
        function Invoke-RawFixture { param([switch]$RequireApproved)
            Test-ThirdPartySkillSource -SourceRoot $sourceRoot -DescriptorPath $descriptorPath -ArchivePath $archivePath -SourceRepository $descriptor.repository -SourceRevision ('a' * 40) -RequireApproved:$RequireApproved
        }
    }
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        Write-RawFixture $sourceRoot 'skills/sample/SKILL.md' "---`nname: sample`ndescription: Render small diagrams.`nlicense: MIT`n---`n# Sample`n"
        Write-RawFixture $sourceRoot 'skills/sample/references/design.md' '# Design'
        Write-RawFixture $sourceRoot 'LICENSE' 'fixture license text'
        $archivePath = Join-Path $caseRoot 'source.zip'
        New-RawFixtureArchive
        $descriptorPath = Join-Path $caseRoot 'adoption.json'
        $descriptor = [ordered]@{
            schemaVersion=1; contract='third-party-raw-skill-source-v1'; sourceId='sample-source'
            repository='https://github.com/example/raw-skills.git'; resolvedCommit=('a'*40)
            archiveSha256=(Get-FileHash $archivePath).Hash.ToLowerInvariant(); reviewState='candidate'; reviewEvidence=@()
            licenseReview='pending'; licenseEvidence=@(); skills=@([ordered]@{
                id='sample'; sourcePath='skills/sample'; targetPath='.agents/skills/sample'
                contentSha256=(Get-SkillInventorySha256 -RepositoryRoot $sourceRoot -SkillRoot (Join-Path $sourceRoot 'skills/sample'))
                upstreamMetadata=[ordered]@{sourceInventory='absent'; openaiInterface='absent'}
                hostInterface=[ordered]@{displayName='Sample Diagrams'; shortDescription='Create diagrams from maintained source'; defaultPrompt='Use $sample to render the supplied diagram.'}
            })
            licenseDocuments=@([ordered]@{path='LICENSE'; sha256=(Get-FileHash (Join-Path $sourceRoot 'LICENSE')).Hash.ToLowerInvariant()})
        }
        Write-RawDescriptor
    }

    # Scenario: An unmodified package lacks source-owned metadata and has a central candidate descriptor.
    # Purpose: Verify original bytes without projecting fabricated source artifacts or claiming release approval.
    It 'UnitT10_validates_candidate_identity_and_complete_inventory_without_installing_metadata' {
        $report = Invoke-RawFixture
        $report.status | Should Be 'passed'
        $report.validationKind | Should Be 'third-party-package-only'
        $report.releaseEligible | Should Be $false
        $report.adoptionApproved | Should Be $false
        @($report.componentInventory).Count | Should Be 3
        $report.skills[0].contentSha256 | Should Be $descriptor.skills[0].contentSha256
        Test-Path (Join-Path $sourceRoot 'catalog/source.json') | Should Be $false
        Test-Path (Join-Path $sourceRoot 'skills/sample/agents/openai.yaml') | Should Be $false
    }

    # Scenario: A different source identity or archive is supplied with a valid descriptor.
    # Purpose: Prevent replay against a mutable ref or another archive/source.
    It 'UnitT20_rejects_wrong_revision_repository_and_archive' {
        { Test-ThirdPartySkillSource -SourceRoot $sourceRoot -DescriptorPath $descriptorPath -ArchivePath $archivePath -SourceRepository $descriptor.repository -SourceRevision 'main' } | Should Throw
        { Test-ThirdPartySkillSource -SourceRoot $sourceRoot -DescriptorPath $descriptorPath -ArchivePath $archivePath -SourceRepository 'https://github.com/example/other.git' -SourceRevision ('a'*40) } | Should Throw
        [IO.File]::WriteAllText($archivePath,'changed archive')
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: A resource is changed or added after inventory binding.
    # Purpose: Protect the complete package rather than validating only SKILL.md.
    It 'UnitT30_rejects_changed_and_unlisted_package_bytes' {
        Write-RawFixture $sourceRoot 'skills/sample/references/new.md' '# Hidden new resource'
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: Source bytes and their descriptor hash are changed while the acquired archive stays original.
    # Purpose: Prove the package comes from that archive, even if a descriptor accidentally binds other bytes.
    It 'UnitT35_rejects_a_tree_and_descriptor_that_do_not_match_the_original_archive' {
        Write-RawFixture $sourceRoot 'skills/sample/references/design.md' '# Different source tree'
        $descriptor.skills[0].contentSha256=Get-SkillInventorySha256 -RepositoryRoot $sourceRoot -SkillRoot (Join-Path $sourceRoot 'skills/sample')
        Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: JSON contains unknown, duplicate or case-conflicting keys, or an escaping source path.
    # Purpose: Keep alternate ownership strict and parser-independent.
    It 'UnitT40_rejects_ambiguous_fields_and_unsafe_paths' {
        $descriptor.unexpected=$true; Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
        $descriptor.Remove('unexpected'); $descriptor.skills[0].sourcePath='../sample'; Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
        $descriptor.skills[0].sourcePath='skills/sample'; Write-RawDescriptor
        $text=[IO.File]::ReadAllText($descriptorPath)
        [IO.File]::WriteAllText($descriptorPath,$text.Replace('"schemaVersion": 1','"schemaVersion": 1, "schemaVersion": 1'))
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: A license is altered or its descriptor points outside the adopted ancestor scope.
    # Purpose: Bind necessary legal documents to the same reviewed source.
    It 'UnitT50_rejects_missing_changed_or_unrelated_license_documents' {
        Write-RawFixture $sourceRoot 'LICENSE' 'changed license'
        { Invoke-RawFixture } | Should Throw
        $descriptor.licenseDocuments[0].path='unrelated/NOTICE'; Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: A candidate requests the approved route before actual review and license disposition.
    # Purpose: A package-only pass cannot enable formal adoption.
    It 'UnitT60_requires_review_evidence_and_license_acceptance_for_approved_adoption' {
        { Invoke-RawFixture -RequireApproved } | Should Throw
        $descriptor.reviewState='approved'; Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
        $descriptor.reviewEvidence=@('https://example.org/review/1'); $descriptor.licenseReview='accepted'; $descriptor.licenseEvidence=@('https://example.org/legal/1'); Write-RawDescriptor
        $report=Invoke-RawFixture -RequireApproved
        $report.adoptionApproved | Should Be $true
        $report.releaseEligible | Should Be $false
    }

    # Scenario: Metadata appears although the raw source declares it absent.
    # Purpose: Avoid applying the alternate path to a source with a different ownership contract.
    It 'UnitT70_rejects_source_owned_metadata_conflicts' {
        Write-RawFixture $sourceRoot 'catalog/source.json' '{}'
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: A declared legal document is accessed through a reparse-backed ancestor.
    # Purpose: Reject out-of-snapshot reads before hashing the document.
    It 'UnitT80_rejects_reparse_backed_license_documents' {
        $outside=Join-Path $caseRoot 'outside'; [void][IO.Directory]::CreateDirectory($outside)
        Write-RawFixture $outside 'NOTICE' 'outside content'
        $kind=if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {'Junction'} else {'SymbolicLink'}
        New-Item -ItemType $kind -Path (Join-Path $sourceRoot 'LICENSES') -Target $outside -ErrorAction Stop | Out-Null
        $descriptor.licenseDocuments[0].path='LICENSES/NOTICE'; $descriptor.licenseDocuments[0].sha256=(Get-FileHash (Join-Path $outside 'NOTICE')).Hash.ToLowerInvariant(); Write-RawDescriptor
        { Invoke-RawFixture } | Should Throw
    }

    # Scenario: The published deidentified example evolves beside the strict descriptor schema.
    # Purpose: Keep a reviewable example without presenting illustrative hashes as an approved adoption.
    It 'UnitT90_keeps_the_synthetic_example_schema_valid_and_unapproved' {
        $standard=Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards'
        $text=Get-Content -Raw (Join-Path $standard 'examples/third-party-raw-skill-source-v1.json')
        Test-Json -Json $text -SchemaFile (Join-Path $standard 'schemas/third-party-raw-skill-source-v1.schema.json') -ErrorAction Stop | Should Be $true
        ($text|ConvertFrom-Json).reviewState | Should Be 'candidate'
        ($text|ConvertFrom-Json).licenseReview | Should Be 'pending'
    }
}
