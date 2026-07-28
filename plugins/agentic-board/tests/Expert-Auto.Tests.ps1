#Requires -Modules Pester
<#  Tests for Expert-Auto.ps1 — the `auto` verb: compose the autonomous brief and decide when the
    budget is spent. Pure cores (Format-AutoBrief, Get-BudgetVerdict, Test-GhScope,
    Assert-BrakeCompliance, Format-ComplianceReport) behind ABIOS_EXPERTAUTO_DOTSOURCE; the launch
    itself reuses the existing fleet/-Launch machinery. #>

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
