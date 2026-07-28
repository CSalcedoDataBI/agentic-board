#Requires -Modules Pester
<#  Tests for Expert-Auto.ps1 — the `auto` verb: compose the autonomous brief and decide when the
    budget is spent. Pure cores (Format-AutoBrief, Get-BudgetVerdict) behind
    ABIOS_EXPERTAUTO_DOTSOURCE; the launch itself reuses the existing fleet/-Launch machinery. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-Auto.ps1' | Resolve-Path
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = ''
    $script:Contract = @{
        role = "You are an expert in powerbi-report. Objective: ship a bar chart."
        autonomy = @{ irreversible = @('merge','deploy','refresh','publish','delete') }
        dod = @{ ci = $true; build = $true; lint = $true; tests = $true; bpa = $true; tmdlBreaking = $true }
        budget = @{ maxIterations = 8; maxMinutes = 120 }
    }
}

Describe 'Format-AutoBrief' {
    It 'embeds the role objective and the plan body' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'Deliver a Deneb visual' -RoleObjective $script:Contract.role
        $b | Should -Match 'expert in powerbi-report'
        $b | Should -Match 'Deliver a Deneb visual'
    }
    It 'lists the definition-of-done gates that must pass' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'ci'
        $b | Should -Match 'bpa'
    }
    It 'spells out the capability map (total self-use of agentic-board)' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '/knowledge'
        $b | Should -Match '/board'
        $b | Should -Match '/skills'
    }
    It 'states the irreversible line explicitly (brake before merge)' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)stop before'
        $b | Should -Match 'merge'
        $b | Should -Match 'delete'
    }
}

Describe 'Get-BudgetVerdict' {
    It 'continues while within the budget' {
        Get-BudgetVerdict -ElapsedMinutes 10 -Iterations 1 -Contract $script:Contract | Should -Be 'continue'
    }
    It 'hands off past the minute budget' {
        Get-BudgetVerdict -ElapsedMinutes 121 -Iterations 1 -Contract $script:Contract | Should -Be 'handoff'
    }
    It 'hands off at the iteration cap' {
        Get-BudgetVerdict -ElapsedMinutes 5 -Iterations 8 -Contract $script:Contract | Should -Be 'handoff'
    }
}

Describe 'Agent type in the autonomous brief' {
    It 'names the role agent when the contract carries one' {
        $c = $script:Contract.Clone()
        $c.roleAgent = 'infra-reviewer'
        $brief = Format-AutoBrief -Contract $c -PlanBody 'do the thing' -RoleObjective 'You are an expert in infra.'
        $brief | Should -Match 'infra-reviewer'
    }
    It 'omits the agent line when the contract names none' {
        $brief = Format-AutoBrief -Contract $script:Contract -PlanBody 'do the thing' -RoleObjective 'You are an expert.'
        $brief | Should -Not -Match 'Adopt the agent type'
    }
}
