Describe 'Third-party raw package source dispatch envelope' {
    BeforeAll {
        function Assert-RawTestEqual {
            param($Actual,$Expected)
            if ($Actual -cne $Expected) { throw "Raw source assertion failed: expected [$Expected], actual [$Actual]." }
        }
        function Assert-RawTestThrows {
            param([scriptblock]$Action)
            $rejected=$false
            try { & $Action | Out-Null } catch { $rejected=$true }
            if (-not $rejected) { throw 'The invalid raw source operation must throw.' }
        }

        Import-Module (Join-Path $PSScriptRoot '../scripts/skills-source-acquisition.psm1') -Force
        $script:EnvelopeCli=Join-Path $PSScriptRoot '../scripts/Validate-ThirdPartySkillSource.ps1'
    }
    BeforeEach {
        $caseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot=Join-Path $caseRoot 'source'
        [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'skills/sample'))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'skills/sample/SKILL.md'),"---`nname: sample`ndescription: Create source diagrams.`n---`n# Sample`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'LICENSE'),'fixture license',[Text.UTF8Encoding]::new($false))
        $archivePath=Join-Path $caseRoot 'original.zip'
        $zip=[IO.Compression.ZipFile]::Open($archivePath,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($relative in @('skills/sample/SKILL.md','LICENSE')) {
                $stream=$zip.CreateEntry('snapshot/'+$relative).Open()
                try {$bytes=[IO.File]::ReadAllBytes((Join-Path $sourceRoot $relative));$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
            }
        } finally {$zip.Dispose()}
        $descriptor=[ordered]@{
            schemaVersion=1;contract='third-party-raw-skill-source-v1';sourceId='sample-source';repository='https://github.com/example/raw-skills.git';resolvedCommit=('a'*40)
            archiveSha256=(Get-FileHash $archivePath).Hash.ToLowerInvariant();reviewState='approved';reviewEvidence=@('https://example.org/review/1');licenseReview='accepted';licenseEvidence=@('https://example.org/legal/1')
            skills=@([ordered]@{id='sample';sourcePath='skills/sample';targetPath='.agents/skills/sample';contentSha256=(Get-SkillInventorySha256 -RepositoryRoot $sourceRoot -SkillRoot (Join-Path $sourceRoot 'skills/sample'));upstreamMetadata=@{sourceInventory='absent';openaiInterface='absent'};hostInterface=@{displayName='Sample Diagrams';shortDescription='Create source-maintained diagrams';defaultPrompt='Use $sample to redraw the supplied source.'}})
            licenseDocuments=@(@{path='LICENSE';sha256=(Get-FileHash (Join-Path $sourceRoot 'LICENSE')).Hash.ToLowerInvariant()})
        }
        $descriptorPath=Join-Path $caseRoot 'adoption.json'
        [IO.File]::WriteAllText($descriptorPath,($descriptor|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $dispatch=@{SourceRoot=$sourceRoot;DescriptorPath=$descriptorPath;ArchivePath=$archivePath;SourceRepository=$descriptor.repository;SourceRevision=('a'*40);OutputPath=(Join-Path $caseRoot 'raw-report.json');SourceValidationEnvelope=$true}
        $names=@('STANDARD_VALIDATION_CANDIDATE_ROOT','STANDARD_VALIDATION_CANDIDATE_ID','STANDARD_VALIDATION_ACTIVE_SKILLS','STANDARD_VALIDATION_STAGE_ID','STANDARD_VALIDATION_TOOL_ID')
        $previous=@{}
        foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name)}
        $env:STANDARD_VALIDATION_CANDIDATE_ROOT=$sourceRoot
        $env:STANDARD_VALIDATION_CANDIDATE_ID='b'*64
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS='sample'
        $env:STANDARD_VALIDATION_STAGE_ID='package-validation'
        $env:STANDARD_VALIDATION_TOOL_ID='package-adapter'
    }
    AfterEach {foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name])}}

    # Scenario: The canonical source runner dispatches an approved raw package adapter.
    # Purpose: Produce a candidate-bound package envelope, retaining raw evidence and release ineligibility.
    It 'InterT10_emits_the_canonical_package_envelope_and_raw_evidence' {
        $output=@(& $script:EnvelopeCli @dispatch)
        $envelope=($output -join "`n")|ConvertFrom-Json
        Assert-RawTestEqual ($envelope.candidateIdentity) (('b'*64))
        Assert-RawTestEqual ($envelope.activeSkills[0]) ('sample')
        Assert-RawTestEqual ($envelope.decision) ('PASS')
        Assert-RawTestEqual ($envelope.adapterStatus) ('passed')
        $raw=Get-Content -Raw $dispatch.OutputPath|ConvertFrom-Json
        Assert-RawTestEqual ($raw.releaseEligible) ($false)
        Assert-RawTestEqual ($raw.adoptionApproved) ($true)
        Assert-RawTestEqual ($raw.archiveProjectionVerified) ($true)
    }

    # Scenario: Dispatch supplies a different active inventory, candidate root or non-package stage.
    # Purpose: Reject replay and prevent the utility from claiming scanner or lifecycle results.
    It 'InterT20_rejects_mismatched_supervisor_context' {
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS='other'
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch }
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS='sample'
        $env:STANDARD_VALIDATION_STAGE_ID='skillspector-static'
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch }
        $env:STANDARD_VALIDATION_STAGE_ID='package-validation'
        $env:STANDARD_VALIDATION_TOOL_ID='skillspector-static'
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch }
        $env:STANDARD_VALIDATION_TOOL_ID='package-adapter'
        $env:STANDARD_VALIDATION_CANDIDATE_ROOT=Join-Path $caseRoot 'different-candidate'
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch }
    }

    # Scenario: The source runner checks an intact candidate before adoption and license review are complete.
    # Purpose: Collect source evidence without requiring or granting release or adoption approval.
    It 'InterT30_checks_a_pending_candidate_without_granting_adoption_approval' {
        $descriptor.reviewState='candidate';$descriptor.licenseReview='pending'
        $descriptor.reviewEvidence=@();$descriptor.licenseEvidence=@()
        [IO.File]::WriteAllText($descriptorPath,($descriptor|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $output=@(& $script:EnvelopeCli @dispatch)
        $envelope=($output -join "`n")|ConvertFrom-Json
        Assert-RawTestEqual ($envelope.candidateIdentity) (('b'*64))
        Assert-RawTestEqual ($envelope.activeSkills[0]) ('sample')
        Assert-RawTestEqual ($envelope.decision) ('PASS')
        Assert-RawTestEqual ($envelope.rawSourceEvidence.adoptionApproved) ($false)
        Assert-RawTestEqual ($envelope.rawSourceEvidence.releaseEligible) ($false)
        $raw=Get-Content -Raw $dispatch.OutputPath|ConvertFrom-Json
        Assert-RawTestEqual ($raw.archiveProjectionVerified) ($true)
        Assert-RawTestEqual ($raw.adoptionApproved) ($false)
        Assert-RawTestEqual ($raw.releaseEligible) ($false)
    }

    # Scenario: An adoption caller explicitly requires approval for a candidate that remains pending.
    # Purpose: Source validation eligibility must not bypass the separate adoption approval requirement.
    It 'InterT35_rejects_pending_adoption_when_approval_is_explicitly_required' {
        $descriptor.reviewState='candidate';$descriptor.licenseReview='pending'
        $descriptor.reviewEvidence=@();$descriptor.licenseEvidence=@()
        [IO.File]::WriteAllText($descriptorPath,($descriptor|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch -RequireApproved }
        Assert-RawTestEqual (Test-Path -LiteralPath $dispatch.OutputPath) ($false)
    }

    # Scenario: A descriptor claims approval without accepted license evidence.
    # Purpose: Accepting pending source checks must not accept fabricated approved adoption claims.
    It 'InterT40_rejects_an_unsubstantiated_approved_claim_in_source_dispatch' {
        $descriptor.licenseReview='pending';$descriptor.licenseEvidence=@()
        [IO.File]::WriteAllText($descriptorPath,($descriptor|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Assert-RawTestThrows { & $script:EnvelopeCli @dispatch }
        Assert-RawTestEqual (Test-Path -LiteralPath $dispatch.OutputPath) ($false)
    }
}
