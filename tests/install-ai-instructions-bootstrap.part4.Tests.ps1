. (Join-Path $PSScriptRoot 'install-ai-instructions-bootstrap.TestSupport.ps1')

Describe 'SYP-511 installer capability evidence persistence' {
    BeforeEach {
        $repositoryRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $caseRoot=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $isolatedHome=Join-Path $caseRoot 'home'
        $codexHome=Join-Path $isolatedHome '.codex'
        New-Item -ItemType Directory -Force -Path $isolatedHome|Out-Null
    }

    # Scenario: A V3V5 install declares two unsorted capability records, then Auto carries them forward and an explicit clear removes them.
    # Purpose: Persist deterministic config v5 evidence, preserve it when no input is supplied, and provide a byte-stable clear operation.
    It 'InterT10_persists_carries_and_clears_capability_evidence_in_config_v5' {
        $evidence='[{"kind":"environment","id":"jira-cloud-api","state":"configured"},{"kind":"connector","id":"datadog","state":"configured"}]'
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema V3V5 -CapabilityEvidence $evidence|Out-Null
        $configurationPath=Join-Path $codexHome 'ai-instructions-sync.json'
        $configuration=Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json
        @($configuration.capabilityEvidence|ForEach-Object{"$($_.kind):$($_.id):$($_.state)"})|Should Be @('connector:datadog:configured','environment:jira-cloud-api:configured')
        $persistedBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath))

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema Auto|Out-Null
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configurationPath))|Should Be $persistedBytes

        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema Auto -ClearCapabilityEvidence|Out-Null
        $cleared=Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json
        $cleared.PSObject.Properties.Name|Should Not Contain 'capabilityEvidence'
    }

    # Scenario: The legacy environment variable supplies configured evidence during a V3V5 install, followed by an explicit absent replacement.
    # Purpose: Preserve compatibility with the old declaration surface while making later modification durable and explicit.
    It 'InterT20_persists_environment_input_and_replaces_it_with_absent' {
        $configured='[{"kind":"connector","id":"datadog","state":"configured"}]'
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema V3V5 -CapabilityEvidenceEnvironment $configured|Out-Null
        $configurationPath=Join-Path $codexHome 'ai-instructions-sync.json'
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json).capabilityEvidence[0].state|Should Be 'configured'

        $absent='[{"kind":"connector","id":"datadog","state":"absent"}]'
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema Auto -CapabilityEvidence $absent|Out-Null
        [string](Get-Content -Raw -Encoding UTF8 -LiteralPath $configurationPath|ConvertFrom-Json).capabilityEvidence[0].state|Should Be 'absent'
    }

    # Scenario: CLI inputs conflict, contain invalid JSON, or repeat one capability tuple before a fresh installation.
    # Purpose: Refuse ambiguous declarations before creating or changing any Codex Home artifact.
    It 'InterT30_rejects_conflicting_invalid_and_duplicate_inputs_before_mutation' {
        $cases=@(
            @{Name='mutually exclusive';Parameters=@{CapabilityEvidence='[]';ClearCapabilityEvidence=$true}},
            @{Name='invalid JSON';Parameters=@{CapabilityEvidence='{invalid'}},
            @{Name='duplicate tuple';Parameters=@{CapabilityEvidence='[{"kind":"connector","id":"datadog","state":"configured"},{"kind":"connector","id":"datadog","state":"absent"}]'}}
        )
        foreach($case in $cases){
            $caseHome=Join-Path $caseRoot ([string]$case.Name).Replace(' ','-')
            $caseCodex=Join-Path $caseHome '.codex'
            New-Item -ItemType Directory -Force -Path $caseHome|Out-Null
            $before=Get-InstallerFullTreeSnapshot -Root $caseCodex
            $parameters=$case.Parameters
            {Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $caseCodex -IsolatedUserHome $caseHome -WriterSchema V3V5 @parameters|Out-Null}|Should Throw
            (Get-InstallerFullTreeSnapshot -Root $caseCodex)|Should Be $before
        }
    }

    # Scenario: An installed V2V4 runtime receives either persistence switch through V2V4 or Auto.
    # Purpose: Refuse config-v5-only evidence before changing any existing Codex Home bytes and point the caller to V3V5.
    It 'InterT40_rejects_capability_persistence_on_the_v2v4_writer_without_mutation' {
        Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema V2V4|Out-Null
        foreach($writer in @('V2V4','Auto')){
            $before=Get-InstallerFullTreeSnapshot -Root $codexHome
            $message=$null
            try{Invoke-InstallScript -RepositoryRoot $repositoryRoot -CodexHome $codexHome -IsolatedUserHome $isolatedHome -WriterSchema $writer -CapabilityEvidence '[]'|Out-Null}catch{$message=$_.Exception.Message}
            $message|Should Match 'WriterSchema V3V5'
            (Get-InstallerFullTreeSnapshot -Root $codexHome)|Should Be $before
        }
    }
}
