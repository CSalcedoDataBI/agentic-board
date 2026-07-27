#Requires -Modules Pester
<#  Tests for Board-Plan.ps1 — the /board plan epic creator.

    Side-effecting (creates issues over gh), so it exposes a dot-source guard: with
    $env:ABIOS_BOARDPLAN_DOTSOURCE set it returns after defining the pure body formatter.
    These tests pin Format-EnrichedEpicBody — the enriched epic body that carries the four
    standard items the /board expert auto-mode reads (Research, Role seed, Deliverables,
    Test plan / DoD). An omitted section must render a detectable TBD placeholder so `auto`
    can tell an enriched-but-unfilled plan from a filled one. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Plan.ps1' | Resolve-Path
    $env:ABIOS_BOARDPLAN_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDPLAN_DOTSOURCE = ''
    $script:Placeholder = '_TBD'
}

Describe 'Format-EnrichedEpicBody' {
    It 'renders all five standard headings' {
        $b = Format-EnrichedEpicBody -Goal 'Build X' -Research 'Prior art: Ralph' `
            -RoleSeed 'Expert in Power BI visuals' -Deliverables @('a script','a command') `
            -TestPlan @('CI green','BPA clean')
        $b | Should -Match '## Goal'
        $b | Should -Match '## Research / Prior-art'
        $b | Should -Match '## Expert role \(seed\)'
        $b | Should -Match '## Deliverables'
        $b | Should -Match '## Test plan \(Definition of Done\)'
    }

    It 'embeds the goal, research and role text' {
        $b = Format-EnrichedEpicBody -Goal 'Build X' -Research 'Prior art: Ralph' `
            -RoleSeed 'Expert in Power BI visuals' -Deliverables @('a script') -TestPlan @('CI green')
        $b | Should -Match 'Build X'
        $b | Should -Match 'Prior art: Ralph'
        $b | Should -Match 'Expert in Power BI visuals'
    }

    It 'renders deliverables and test-plan as bullet lists' {
        $b = Format-EnrichedEpicBody -Goal 'g' -Research 'r' -RoleSeed 's' `
            -Deliverables @('first deliverable','second deliverable') -TestPlan @('lint passes')
        $b | Should -Match '- first deliverable'
        $b | Should -Match '- second deliverable'
        $b | Should -Match '- lint passes'
    }

    It 'renders a detectable TBD placeholder for an omitted section' {
        $b = Format-EnrichedEpicBody -Goal 'g'   # research/role/deliverables/testplan omitted
        $b | Should -Match ([regex]::Escape($script:Placeholder))
    }

    It 'a fully-omitted body still has every heading (all TBD)' {
        $b = Format-EnrichedEpicBody
        $b | Should -Match '## Goal'
        $b | Should -Match '## Test plan \(Definition of Done\)'
        ([regex]::Matches($b, [regex]::Escape($script:Placeholder))).Count | Should -BeGreaterOrEqual 5
    }
}
