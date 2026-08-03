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

Describe 'Format-AutoBrief — phase loop and decision protocol (#527)' {
    # #527: the brief was a capability LIST — the 7-phase loop and the research-before-deciding
    # protocol lived in auto-loop.md, a file the launched session never received. The session
    # must carry the METHOD (phases + decision protocol), not just a bullet list of capabilities.

    It 'includes all seven phases so the session knows the method, not just the capability list' {
        # Asserted on the NUMBERED phase markers, not on bare words: 'verify' and 'report' also
        # occur in the capability map, so a bare-word match would stay green with the phases gone.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?im)^1\. \*\*Ingest\*\*'
        $b | Should -Match '(?im)^2\. \*\*Become the expert\*\*'
        $b | Should -Match '(?im)^3\. \*\*Execute'
        $b | Should -Match '(?im)^4\. \*\*Verify'
        $b | Should -Match '(?im)^5\. \*\*Self-heal'
        $b | Should -Match '(?im)^6\. \*\*Loop until'
        $b | Should -Match '(?im)^7\. \*\*Report\*\*'
    }
    It 'carries the decision protocol — research before deciding, not act first' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)research.*before deciding'
    }
    It 'names the decision protocol steps in order: research, register, decide' {
        # Scoped to the decision-protocol SECTION. Measuring first-occurrence over the whole brief
        # would read 'Research' out of phase 2 and pass even with the protocol steps scrambled.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('### Decision protocol', [System.StringComparison]::OrdinalIgnoreCase)
        $start | Should -BeGreaterThan -1
        $next = $b.IndexOf('### ', $start + 4, [System.StringComparison]::OrdinalIgnoreCase)
        $section = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }

        $iR = $section.IndexOf('1. Research', [System.StringComparison]::OrdinalIgnoreCase)
        $iReg = $section.IndexOf('2. Register', [System.StringComparison]::OrdinalIgnoreCase)
        $iD = $section.IndexOf('3. Decide', [System.StringComparison]::OrdinalIgnoreCase)
        $iR | Should -BeGreaterThan -1
        $iR | Should -BeLessThan $iReg
        $iReg | Should -BeLessThan $iD
    }
    It 'keeps the do-NOT-improvise guard the old brief carried (regression, found in review)' {
        # The rewrite dropped 'total self-use ... (do NOT improvise your own tooling)' from the ONLY
        # text the session receives. A capability map lists options; it does not forbid inventing one.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)total self-use of agentic-board'
        $b | Should -Match '(?i)do NOT improvise your own tooling'
    }
    It 'says read-and-forget is not research (the decision protocol standard)' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)read-and-forget'
    }
}

Describe 'Format-AutoBrief — an ordered run is told the order is inert, not that it may close (#541)' {
    # #536 had the brief GRANT the close. Review then found the mechanism behind it had two holes
    # it could not defend, so the grant was withdrawn. The brief must not silently go back to a
    # bare "STOP" either: a run carrying an order it was never told about would read its own
    # refusal as failure and hunt for a way around it.

    It 'still orders the stop when there is no order' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'STOP'
        $b | Should -Match 'Do NOT merge'
    }
    It 'does NOT grant the close when ordered' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Not -Match 'you MAY close this work yourself'
    }
    It 'still orders the stop when ordered' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match 'STOP'
    }
    It 'acknowledges the order rather than pretending it was never given' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match '(?i)ordered this run end to end'
        $b | Should -Match '(?i)recorded'
    }
    It 'tells the run a refusal is the control working, not a bug to route around' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match '(?i)working as intended'
        $b | Should -Match '(?i)another way'
    }
    It 'points at the issue so the state is checkable rather than asserted' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Match '#541'
    }
    It 'names no merge path at all — there is none to name' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' -EndToEnd
        $b | Should -Not -Match 'Board-Merge\.ps1'
    }
}
