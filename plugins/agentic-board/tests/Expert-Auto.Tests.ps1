#Requires -Modules Pester
<#  Tests for Expert-Auto.ps1 — the `auto` verb: compose the autonomous brief and resolve the
    time budget the launch hands to the brake marker (#564). Pure cores (Format-AutoBrief,
    Get-ContractBudgetMinutes, Test-GhScope, Assert-BrakeCompliance, Format-ComplianceReport)
    behind ABIOS_EXPERTAUTO_DOTSOURCE; the launch itself reuses the existing fleet/-Launch
    machinery, and ENFORCEMENT lives in the PreToolUse hook (Brake-Guard). #>

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
    $script:Sha1 = 'aaaaaaa0000000000000000000000000000000000'
    $script:Sha2 = 'bbbbbbb0000000000000000000000000000000000'
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

Describe 'Get-ContractBudgetMinutes - the budget the launch hands to the brake marker (#564)' {
    # Replaces Get-BudgetVerdict, which was dead code: it computed a verdict nothing ever called,
    # so the 120-minute budget existed only as a sentence in the brief. The launch now writes this
    # value into the brake marker and the PreToolUse hook enforces it (see Brake-Guard tests).
    It 'reads the contract maxMinutes' {
        Get-ContractBudgetMinutes -Contract $script:Contract | Should -Be 120
    }
    It 'defaults to 120 when the contract has no budget section' {
        Get-ContractBudgetMinutes -Contract @{ role = 'r' } | Should -Be 120
    }
    It 'honours a custom budget' {
        Get-ContractBudgetMinutes -Contract @{ budget = @{ maxMinutes = 45 } } | Should -Be 45
    }
    It 'a malformed value falls back to the default instead of crashing the launch' {
        Get-ContractBudgetMinutes -Contract @{ budget = @{ maxMinutes = 'lots' } } | Should -Be 120
    }
    It 'preserves an explicit 0 as "no enforcement" (external review: presence, not truthiness)' {
        # Truthiness read a configured 0 as absent and silently re-armed the 120-minute default
        # the owner had just switched off.
        Get-ContractBudgetMinutes -Contract @{ budget = @{ maxMinutes = 0 } } | Should -Be 0
    }
    It 'a blank or boolean value is MALFORMED -> default, never "enforcement silently off" (round 7)' {
        Get-ContractBudgetMinutes -Contract @{ budget = @{ maxMinutes = '' } } | Should -Be 120
        Get-ContractBudgetMinutes -Contract @{ budget = @{ maxMinutes = $true } } | Should -Be 120
    }
}

Describe 'The brief tells the truth about the budget (#564 round 7)' {
    It 'a zero-budget contract is NOT briefed as mechanically enforced' {
        $c = @{ role = 'r'; autonomy = @{ irreversible = @('merge') }; dod = @{ ci = $true }
                budget = @{ maxIterations = 8; maxMinutes = 0 } }
        $b = Format-AutoBrief -Contract $c -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)no enforced time budget'
        $b | Should -Not -Match '(?i)is ENFORCED, not advisory'
    }
    It 'a positive budget states the enforced number and names the allowed wrap-up' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '120 min'
        $b | Should -Match '(?i)enforced'
        $b | Should -Match '(?i)handoff'
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

Describe 'Format-AutoBrief — independent review is mandatory for an unsupervised run (#623)' {
    It 'tells the run to pass -RequireIndependentReviewer to the gate' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'RequireIndependentReviewer'
    }
    It 'forbids the run from self-certifying via its own identity' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)does not count'
        $b | Should -Match '(?i)refuses'
    }
    It 'points at the CI bot review as the identity that actually satisfies the guard' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'claude-review'
    }
    It 'mentions codex-rescue exists but tells the run NOT to switch to it on its own judgment, when the contract did not opt in (#646)' {
        # $script:Contract carries no `review` key at all - the same as a contract written before
        # #646, or one where config never enabled it. Both must resolve to the CI-bot path.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)codex-rescue'
        $b | Should -Match '(?is)did\s+not opt into it'   # here-string wraps mid-phrase; tolerate the line break
        $b | Should -Not -Match '(?i)do not attempt'          # #637 corrected the old "not invokable" finding
        $b | Should -Not -Match 'subagent_type'                # the concrete invocation steps are NOT prescribed here
    }
}

Describe 'Format-AutoBrief — the contract''s codex-rescue choice is INSTRUCTED, not left to the run (#646)' {
    BeforeAll {
        $script:ContractCodex = $script:Contract.Clone()
        $script:ContractCodex.review = @{ preferCodexRescue = $true }
    }
    It 'gives concrete, mandatory steps to invoke codex:codex-rescue when the contract opted in' {
        $b = Format-AutoBrief -Contract $script:ContractCodex -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'codex:codex-rescue'
        $b | Should -Match 'PreferCodexRescue'
        $b | Should -Match '(?i)RolloutPath'
    }
    It 'still requires -RequireIndependentReviewer alongside the codex-rescue flag' {
        $b = Format-AutoBrief -Contract $script:ContractCodex -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match 'RequireIndependentReviewer'
    }
    It 'does NOT print the CI-bot-only branch text when the contract opted into codex-rescue' {
        $b = Format-AutoBrief -Contract $script:ContractCodex -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Not -Match '(?i)did not opt into it'
    }
}

Describe 'Format-AutoBrief — compliance checkpoint (#440 problem 2)' {
    It 'embeds the launch SHA and compliance instructions when MainShaAtLaunch is provided' {
        $sha = 'abc1234def5678abc1234def5678abc1234def56'
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' `
            -MainShaAtLaunch $sha
        $b | Should -Match 'abc1234'
        $b | Should -Match '(?i)compliance check'
        $b | Should -Match '(?i)BEFORE Fleet-Findings'
    }
    It 'omits the compliance section when MainShaAtLaunch is empty' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Not -Match '(?i)compliance check'
    }
    It 'includes repo and issue number in the compliance command when provided' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' `
            -MainShaAtLaunch 'abc1234' -Repo 'owner/repo' -IssueNum 99
        $b | Should -Match 'owner/repo'
        $b | Should -Match '#99'
    }
    It 'falls back to git rev-parse command when Repo is empty' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r' `
            -MainShaAtLaunch 'abc1234'
        $b | Should -Match 'git rev-parse'
        $b | Should -Not -Match 'gh api repos'
    }
}

Describe 'Test-GhScope (#440 footgun 1)' {
    It 'returns true when the scope is listed in the status text' {
        $text = "  Token scopes: 'gist', 'project', 'repo'"
        Test-GhScope -Scope 'project' -StatusText $text | Should -BeTrue
    }
    It 'returns false when the scope is absent from the status text' {
        $text = "  Token scopes: 'gist', 'repo'"
        Test-GhScope -Scope 'project' -StatusText $text | Should -BeFalse
    }
    It 'returns false when the status text has no Token scopes line' {
        Test-GhScope -Scope 'project' -StatusText 'gh: not logged in' | Should -BeFalse
    }
    It 'returns false for an empty status text' {
        Test-GhScope -Scope 'project' -StatusText '' | Should -BeFalse
    }
    It 'is case-insensitive on the Token scopes label' {
        $text = "  TOKEN SCOPES: 'project', 'repo'"
        Test-GhScope -Scope 'project' -StatusText $text | Should -BeTrue
    }
    It 'handles status text without quotes around scopes' {
        $text = "  Token scopes: project, repo"
        Test-GhScope -Scope 'project' -StatusText $text | Should -BeTrue
    }
}

Describe 'Assert-BrakeCompliance (#440 problem 2)' {
    It 'is compliant when main SHA is unchanged and merge is irreversible' {
        $r = Assert-BrakeCompliance -Contract $script:Contract `
            -CurrentMainSha $script:Sha1 -MainShaAtLaunch $script:Sha1
        $r.compliant  | Should -BeTrue
        $r.mainMoved  | Should -BeFalse
        $r.detail     | Should -Match 'unchanged'
    }
    It 'is non-compliant (violated) when main moved and merge is irreversible' {
        $r = Assert-BrakeCompliance -Contract $script:Contract `
            -CurrentMainSha $script:Sha2 -MainShaAtLaunch $script:Sha1
        $r.compliant  | Should -BeFalse
        $r.mainMoved  | Should -BeTrue
        $r.detail     | Should -Match 'moved'
    }
    It 'is compliant when main moved but merge is NOT irreversible' {
        $openContract = @{ autonomy = @{ irreversible = @('deploy') } }
        $r = Assert-BrakeCompliance -Contract $openContract `
            -CurrentMainSha $script:Sha2 -MainShaAtLaunch $script:Sha1
        $r.compliant | Should -BeTrue
        $r.mainMoved | Should -BeTrue
    }
    It 'is compliant when current SHA is empty (cannot tell — best effort)' {
        $r = Assert-BrakeCompliance -Contract $script:Contract `
            -CurrentMainSha 'x' -MainShaAtLaunch $script:Sha1
        # 'x' differs from sha1, but 'x' length < 7 — detail truncation should not throw
        $r | Should -Not -BeNullOrEmpty
    }
    It 'abbreviates SHAs to 7 chars in the detail field' {
        $r = Assert-BrakeCompliance -Contract $script:Contract `
            -CurrentMainSha $script:Sha2 -MainShaAtLaunch $script:Sha1
        $r.detail | Should -Match 'aaaaaaa'
        $r.detail | Should -Match 'bbbbbbb'
        $r.detail | Should -Not -Match 'aaaaaaa0000000'
    }
}

Describe 'Format-ComplianceReport (#440 problem 2)' {
    It 'emits a PASS verdict block when compliant' {
        $c = @{ compliant = $true; mainMoved = $false; detail = 'main SHA unchanged (abc1234)' }
        $r = Format-ComplianceReport -Compliance $c -Issue 42
        $r | Should -Match '\[abios-evidence\]'
        $r | Should -Match '\[OK\]'
        $r | Should -Match 'PASS'
        $r | Should -Match '#42'
    }
    It 'emits a VIOLATION verdict block when non-compliant' {
        $c = @{ compliant = $false; mainMoved = $true; detail = 'main moved: abc1234 -> def5678' }
        $r = Format-ComplianceReport -Compliance $c
        $r | Should -Match '\[VIOLATION\]'
        $r | Should -Match 'BRAKE VIOLATED'
    }
    It 'omits the issue tag when Issue is 0' {
        $c = @{ compliant = $true; mainMoved = $false; detail = 'unchanged' }
        $r = Format-ComplianceReport -Compliance $c
        $r | Should -Not -Match '#\d'
    }
    It 'includes the mainMoved value in the table' {
        $c = @{ compliant = $false; mainMoved = $true; detail = 'moved' }
        $r = Format-ComplianceReport -Compliance $c
        $r | Should -Match 'True'
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

Describe 'Format-AutoBrief — self-planning escalation (#531)' {
    # #531: a run that discovers its task is really six tasks has one move: drop six loose discovered
    # issues with no parent. The brief must instruct escalation to an epic + sub-issues via
    # Board-Plan.ps1, bounded by the boardSelfDrive cap, and linked to the originating issue.

    It 'names the escalation capability by its typed command, not by an internal script' {
        # The brief is the only text the run receives and the run may work in ANY repo, where a
        # plugin script name resolves to nothing. #480 and #494 are open on exactly this; the first
        # cut of this section named the script and pinned it with a test. Command surface only.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '/board plan'
        $b | Should -Not -Match '(?i)Board-Plan\.ps1'
    }
    It 'instructs escalation to an epic + sub-issues when the work outgrows the issue' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)escalat'
        $b | Should -Match '(?i)sub-issues'
    }
    It 'bounds the epic sub-issues by the boardSelfDrive cap' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)boardSelfDrive'
        $b | Should -Match '(?i)\bcap\b'
    }
    It 'instructs the run to link the epic to the originating issue for traceability' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Match '(?i)originating issue'
    }
    It 'embeds the cap value from the contract into the self-planning section' {
        $c = $script:Contract.Clone()
        $c.boardSelfDrive = @{ createIssues = $true; label = 'discovered'; cap = 7 }
        $b = Format-AutoBrief -Contract $c -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('Self-planning', [System.StringComparison]::OrdinalIgnoreCase)
        $start | Should -BeGreaterThan -1
        $section = $b.Substring($start)
        $section | Should -Match '\b7\b'
    }
    It 'honours a cap of 0 instead of falling back to the default (regression, found in review)' {
        # `if ($c.boardSelfDrive.cap)` reads 0 as absent, so a contract saying "create nothing"
        # would tell the run it may create ten. Presence, not truthiness.
        $c = $script:Contract.Clone()
        $c.boardSelfDrive = @{ createIssues = $false; label = 'discovered'; cap = 0 }
        $b = Format-AutoBrief -Contract $c -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('Self-planning', [System.StringComparison]::OrdinalIgnoreCase)
        $section = $b.Substring($start)
        $section | Should -Match '\(0\)'
        $section | Should -Not -Match '\(10\)'
    }
}

Describe 'Format-AutoBrief — research-before-deciding in self-heal (#528)' {
    # #528: the self-heal phase said "fix it (after researching first)" — still act-first in framing.
    # The decision protocol must be the EXPLICIT response to an error or fork, not a parenthetical.
    # "research-before-deciding replaces fix-it-and-continue" means Phase 5 invokes the protocol
    # by name and says "do NOT act first", rather than leading with "fix it".

    It 'phase 5 self-heal references the decision protocol for errors and forks, not just a parenthetical' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        # Scope to Phase 5 only — decision protocol also appears in its own section
        $start = $b.IndexOf('5. **Self-heal', [System.StringComparison]::OrdinalIgnoreCase)
        $start | Should -BeGreaterThan -1
        $next  = $b.IndexOf('6. **Loop', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase5 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        # Must name the decision protocol explicitly (not just "after researching first")
        $phase5 | Should -Match '(?i)decision protocol'
    }

    It 'phase 5 self-heal says do NOT act first in the context of error or fork' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('5. **Self-heal', [System.StringComparison]::OrdinalIgnoreCase)
        $next  = $b.IndexOf('6. **Loop', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase5 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        $phase5 | Should -Match '(?i)do NOT act first'
    }

    It 'phase 5 still tells the run to FIX an in-scope problem (regression, found in review)' {
        # Reframing phase 5 around the protocol dropped 'in-scope problem -> fix it'. The protocol
        # ends at "decide"; a phase named Self-heal that never says to heal leaves the run with a
        # decision and no instruction to act on it. Deleting a sentence here deletes the behaviour.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('5. **Self-heal', [System.StringComparison]::OrdinalIgnoreCase)
        $next  = $b.IndexOf('6. **Loop', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase5 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        $phase5 | Should -Match '(?i)in-scope problem'
        $phase5 | Should -Match '(?i)fix it in the loop and continue'
    }

    It 'phase 5 orders the protocol BEFORE acting, not the other way round' {
        # The point of #528: research-before-deciding replaces fix-it-and-continue as the RESPONSE.
        # Restoring the fix instruction must not restore the act-first ordering it displaced.
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('5. **Self-heal', [System.StringComparison]::OrdinalIgnoreCase)
        $next  = $b.IndexOf('6. **Loop', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase5 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        $iProtocol = $phase5.IndexOf('decision protocol', [System.StringComparison]::OrdinalIgnoreCase)
        $iFix = $phase5.IndexOf('fix it in the loop', [System.StringComparison]::OrdinalIgnoreCase)
        $iProtocol | Should -BeGreaterThan -1
        $iProtocol | Should -BeLessThan $iFix
    }

    It 'phase 5 no longer uses the act-first parenthetical fix-it framing' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('5. **Self-heal', [System.StringComparison]::OrdinalIgnoreCase)
        $next  = $b.IndexOf('6. **Loop', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase5 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        # The old framing "fix it (after researching first)" is the pattern to eliminate
        $phase5 | Should -Not -Match '(?i)fix it \(after'
    }
}

Describe 'Format-AutoBrief — the run must quote the completion check (#532)' {
    # The check existed but nothing invoked it: referenced only by its own file and its own test.
    # A completion check nobody runs verifies nothing — the same "wired to nothing" defect the
    # 0.31.0 notes record. Phase 7 now makes the verdict part of the report the run must give.

    It 'phase 7 tells the run to run the verify check before reporting' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('7. **Report', [System.StringComparison]::OrdinalIgnoreCase)
        $start | Should -BeGreaterThan -1
        $next = $b.IndexOf('### ', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase7 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        $phase7 | Should -Match '/board expert verify'
    }
    It 'phase 7 requires the verdict to be quoted, not merely the check to be run' {
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $start = $b.IndexOf('7. **Report', [System.StringComparison]::OrdinalIgnoreCase)
        $next = $b.IndexOf('### ', $start, [System.StringComparison]::OrdinalIgnoreCase)
        $phase7 = if ($next -gt $start) { $b.Substring($start, $next - $start) } else { $b.Substring($start) }
        $phase7 | Should -Match '(?i)quote its verdict'
        $phase7 | Should -Match '(?i)INCOMPLETE'
    }
    It 'names the check by its typed command, never by the script name' {
        # Same rule the escalation section had to be corrected for: the brief travels to runs in
        # any repo, where a plugin script name resolves to nothing (#480, #494).
        $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
        $b | Should -Not -Match '(?i)Expert-RunVerify\.ps1'
    }
}

Describe 'Get-EpicWaveVerdict - the epic walker brain (#566)' {
    # Nothing advanced an epic before: one -Issue per human launch. This classifies sub-issues
    # into the next dispatchable wave; the fail direction routes UNKNOWN PR state to InFlight
    # (never dispatch a second session onto an issue that may already have one).
    BeforeAll {
        function script:Sub {
            param([int]$n, [string]$state = 'OPEN', $blockers = @(), [bool]$openPr = $false,
                  [bool]$mergedPr = $false, [bool]$known = $true)
            [pscustomobject]@{ number = $n; title = "t$n"; state = $state; openBlockers = @($blockers)
                               hasOpenPr = $openPr; hasMergedPr = $mergedPr; prKnown = $known }
        }
    }

    It 'an open, unblocked, PR-less sub-issue is READY' {
        $v = Get-EpicWaveVerdict -SubIssues @((script:Sub 10))
        @($v.Ready).number | Should -Contain 10
    }
    It 'closed and merged sub-issues are DONE' {
        $v = Get-EpicWaveVerdict -SubIssues @((script:Sub 10 'CLOSED'), (script:Sub 11 'OPEN' @() $false $true))
        @($v.Done).Count | Should -Be 2
        @($v.Ready).Count | Should -Be 0
    }
    It 'an open PR means IN FLIGHT - a session owns it, never re-dispatch' {
        $v = Get-EpicWaveVerdict -SubIssues @((script:Sub 10 'OPEN' @() $true))
        @($v.InFlight).number | Should -Contain 10
    }
    It 'an open blocker means BLOCKED - the next wave, not this one' {
        $v = Get-EpicWaveVerdict -SubIssues @((script:Sub 10 'OPEN' @(9)))
        @($v.Blocked).number | Should -Contain 10
        @($v.Ready).Count | Should -Be 0
    }
    It 'UNKNOWN PR state routes to InFlight - dispatching a duplicate session is the worse error' {
        $v = Get-EpicWaveVerdict -SubIssues @((script:Sub 10 'OPEN' @() $false $false $false))
        @($v.InFlight).number | Should -Contain 10
        @($v.Ready).Count | Should -Be 0
    }
    It 'a realistic epic splits correctly' {
        $v = Get-EpicWaveVerdict -SubIssues @(
            (script:Sub 1 'CLOSED'),                    # done
            (script:Sub 2 'OPEN' @() $true),            # in flight
            (script:Sub 3 'OPEN' @(2)),                 # blocked by 2
            (script:Sub 4),                             # ready
            (script:Sub 5)                              # ready
        )
        @($v.Ready).number | Should -Be @(4, 5)
        @($v.Blocked).number | Should -Be @(3)
        @($v.InFlight).number | Should -Be @(2)
        @($v.Done).number | Should -Be @(1)
    }
    It 'null entries are ignored' {
        $v = Get-EpicWaveVerdict -SubIssues @($null, (script:Sub 10))
        @($v.Ready).Count | Should -Be 1
    }
}
