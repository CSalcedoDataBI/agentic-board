#Requires -Modules Pester
<#  The brief Expert-Auto hands the launched agent must carry the honest-evidence rules (#475, #481).

    PR #693 added the N/A and NOT-EVALUATED evidence states and the review gate's exit 3 ("CI never
    ran"). The evidence block is written by the launched agent following the brief, not by a script,
    so a state the brief never mentions is a state the agent never uses: the helpers would have no
    caller. A review of #693 said exactly that. These pin the wording in the rendered brief. #>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = '1'
    . (Join-Path $script:ScriptsDir 'Expert-Auto.ps1')
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = ''
    $script:Contract = @{
        role = 'You are an expert in powerbi-report. Objective: ship a bar chart.'
        autonomy = @{ irreversible = @('merge', 'deploy', 'refresh', 'publish', 'delete') }
        dod = @{ ci = $true; tests = $true }
        budget = @{ maxIterations = 8; maxMinutes = 120 }
    }
    $script:Brief = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
}

Describe 'the brief tells the agent how to record a gate honestly' {
    It 'names the N/A state for a gate the diff does not owe, and forbids calling it PASS' {
        $script:Brief | Should -Match 'N/A'
        $script:Brief | Should -Match '(?s)does not owe.{0,80}N/A.{0,40}never.{0,10}PASS'
    }
    It 'names the NOT-EVALUATED state for a CI that never ran, and forbids calling it FAIL' {
        $script:Brief | Should -Match '(?s)never executed.{0,80}NOT-EVALUATED.{0,40}never.{0,10}FAIL'
    }
    It 'points at the row builders that produce those states' {
        $script:Brief | Should -Match 'Get-NotApplicableGateRows'
        $script:Brief | Should -Match 'Get-CiEvidenceRow'
    }
}

Describe 'the brief tells the agent to stop re-pushing when the review gate exits 3' {
    It 'names exit 3 and CI NO SE EVALUO' {
        $script:Brief | Should -Match '(?s)exits \*\*3\*\*.{0,40}CI NO SE EVALUO'
    }
    It 'says to stop re-pushing and record the ci gate as NOT-EVALUATED' {
        $script:Brief | Should -Match '(?s)stop re-pushing.{0,80}NOT-EVALUATED'
    }
    It 'still says exit 1 (a real failure) is what the loop is for' {
        $script:Brief | Should -Match '(?s)exit 1.{0,40}real failure.{0,60}loop'
    }
}
