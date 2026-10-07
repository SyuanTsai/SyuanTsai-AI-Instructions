Describe 'Third-party raw package source dispatch envelope' {
    BeforeAll {
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
        $envelope.candidateIdentity | Should Be ('b'*64)
        $envelope.activeSkills[0] | Should Be 'sample'
        $envelope.decision | Should Be 'PASS'
        $envelope.adapterStatus | Should Be 'passed'
        $raw=Get-Content -Raw $dispatch.OutputPath|ConvertFrom-Json
        $raw.releaseEligible | Should Be $false
        $raw.archiveProjectionVerified | Should Be $true
    }

    # Scenario: Dispatch supplies a different active inventory, candidate root or non-package stage.
    # Purpose: Reject replay and prevent the utility from claiming scanner or lifecycle results.
    It 'InterT20_rejects_mismatched_supervisor_context' {
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS='other'
        { & $script:EnvelopeCli @dispatch } | Should Throw
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS='sample'
        $env:STANDARD_VALIDATION_STAGE_ID='skillspector-static'
        { & $script:EnvelopeCli @dispatch } | Should Throw
    }

    # Scenario: A caller omits RequireApproved while dispatching a candidate descriptor through the source route.
    # Purpose: The source envelope must automatically require approved central review and legal disposition.
    It 'InterT30_rejects_candidate_state_in_the_formal_source_route' {
        $descriptor.reviewState='candidate';$descriptor.licenseReview='pending'
        [IO.File]::WriteAllText($descriptorPath,($descriptor|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        { & $script:EnvelopeCli @dispatch } | Should Throw
    }
}
