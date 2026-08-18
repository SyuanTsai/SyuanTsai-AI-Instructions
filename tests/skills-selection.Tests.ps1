$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-selection.psm1') -Force

function New-SelectionCatalog {
    return [pscustomobject]@{
        profiles = @(
            [pscustomobject]@{ id='core'; default=$true; includes=@('skill-a'); excludes=@() },
            [pscustomobject]@{ id='team'; default=$false; includes=@('skill-b','skill-c'); excludes=@('skill-c') }
        )
        skills = @(
            [pscustomobject]@{ id='skill-a'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-b'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-c'; lifecycle=[pscustomobject]@{ status='active' } },
            [pscustomobject]@{ id='skill-old'; lifecycle=[pscustomobject]@{ status='removed' } }
        )
    }
}

Describe 'Skills selection resolver' {
    It 'uses default profiles when no profile is explicitly selected' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@(); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    It 'unions profile includes with explicit includes and applies excludes last' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@('skill-a'); excludeSkills=@('skill-b') }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-a')
    }

    It 'applies profile excludes without domain specific behavior' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('team'); includeSkills=@(); excludeSkills=@() }
        @(Resolve-SkillsSelection -Catalog $catalog -Selection $selection) | Should Be @('skill-b')
    }

    It 'fails closed on an unknown profile' {
        $catalog = New-SelectionCatalog
        $selection = [pscustomobject]@{ profiles=@('missing'); includeSkills=@(); excludeSkills=@() }
        { Resolve-SkillsSelection -Catalog $catalog -Selection $selection } | Should Throw '*Unknown Skills Catalog profile*'
    }

    It 'fails closed when explicit selection references unknown or removed Skills' {
        $catalog = New-SelectionCatalog
        { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('missing'); excludeSkills=@() }) } | Should Throw '*does not exist*'
        { Resolve-SkillsSelection -Catalog $catalog -Selection ([pscustomobject]@{ profiles=@(); includeSkills=@('skill-old'); excludeSkills=@() }) } | Should Throw '*is removed*'
    }
}
