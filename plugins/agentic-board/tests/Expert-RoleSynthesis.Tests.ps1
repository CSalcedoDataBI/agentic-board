#Requires -Modules Pester
<#  Tests for Expert-RoleSynthesis.ps1 — the deterministic skeleton the auto-expert fills.

    The LLM does the actual prior-art research; this script gives the reproducible parts:
    map a plan to a domain, hook the installed skills/profiles relevant to that domain, and
    render the role-as-objective block. Pure (no gh) behind ABIOS_EXPERTROLE_DOTSOURCE. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-RoleSynthesis.ps1' | Resolve-Path
    $env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTROLE_DOTSOURCE = ''
    $script:Inv = @(
        'reports:deneb-visuals','reports:pbi-report-design','svg-visuals',
        'semantic-models:dax','tmdl-review','tabular-editor:bpa-rules',
        'fabric-cli:fabric-cli',
        'skill-creator','writing-skills','second-opinion'   # quality profile
    )
}

Describe 'Get-DomainFromPlan' {
    It 'classifies a Power BI visual plan as powerbi-report' {
        Get-DomainFromPlan -Text 'Build a Power BI visual extension using Deneb' | Should -Be 'powerbi-report'
    }
    It 'classifies a DAX/measure plan as semantic-model' {
        Get-DomainFromPlan -Text 'Add a DAX measure to the semantic model and validate TMDL' | Should -Be 'semantic-model'
    }
    It 'classifies a Fabric lakehouse plan as fabric' {
        Get-DomainFromPlan -Text 'Create a Fabric lakehouse ingestion pipeline' | Should -Be 'fabric'
    }
    It 'falls back to generic for unrelated text' {
        Get-DomainFromPlan -Text 'Refactor the logging helper for clarity' | Should -Be 'generic'
    }
}

Describe 'Get-HookedSkills' {
    It 'hooks report skills for powerbi-report and always adds the quality profile' {
        $h = Get-HookedSkills -Domain 'powerbi-report' -Inventory $script:Inv
        $h | Should -Contain 'reports:deneb-visuals'
        $h | Should -Contain 'skill-creator'          # quality profile always included
        $h | Should -Not -Contain 'fabric-cli:fabric-cli'
    }
    It 'hooks model skills for semantic-model' {
        $h = Get-HookedSkills -Domain 'semantic-model' -Inventory $script:Inv
        $h | Should -Contain 'semantic-models:dax'
        $h | Should -Contain 'tmdl-review'
    }
    It 'generic hooks only the quality profile present in inventory' {
        $h = Get-HookedSkills -Domain 'generic' -Inventory $script:Inv
        $h | Should -Contain 'writing-skills'
        $h | Should -Not -Contain 'reports:deneb-visuals'
    }
}

Describe 'Format-RoleObjective' {
    It 'embeds the goal and the hooked skills' {
        $block = Format-RoleObjective -Domain 'powerbi-report' `
            -HookedSkills @('reports:deneb-visuals','skill-creator') -PlanGoal 'Ship a bar-chart visual'
        $block | Should -Match 'powerbi-report'
        $block | Should -Match 'Ship a bar-chart visual'
        $block | Should -Match 'reports:deneb-visuals'
    }
}
