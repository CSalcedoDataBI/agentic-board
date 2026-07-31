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

Describe 'Format-AutoBrief — the ORDERED end-to-end run (#536)' {
    # The permission was recorded in the brake marker and never reached the agent that had to act
    # on it: the brief said "STOP, do NOT merge" whether or not the owner had ordered the finish.
    # A run cannot obey an instruction it was never given.

    It 'still orders the stop when there is no end-to-end order' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'STOP'
        $b | Should -Match 'Do NOT merge'
    }
    It 'defaults to stopping when the caller says nothing' {
        # Absent parameter must never read as permission granted.
        (Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r') |
            Should -Not -Match 'you MAY close this work yourself'
    }

    It 'grants the finish when ordered' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match 'you MAY close this work yourself'
    }
    It 'names all four conditions so the run knows what it must earn' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match '(?i)code'
        $b | Should -Match '(?i)review'
        $b | Should -Match '(?i)tests'
        $b | Should -Match '(?i)ordered'
    }
    It 'points at the GATED path and forbids the raw merge' {
        # The gated script is the only route the tool layer leaves open in ordered mode; telling
        # the run to reach for `gh pr merge` would just earn it a refusal it cannot interpret.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match 'Board-Merge\.ps1'
        $b | Should -Match 'gh pr merge'
    }
    It 'keeps the OTHER irreversible verbs off the table even when ordered' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match 'deploy'
        $b | Should -Match 'publish'
    }
    It 'does not promise a merge the conditions may refuse' {
        # The brief must not read as "you will merge"; the gate decides at merge time.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match '(?i)refuse|no se cierra|only if|will refuse'
    }
}
