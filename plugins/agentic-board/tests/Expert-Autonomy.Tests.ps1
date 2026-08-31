#Requires -Modules Pester
<#  Tests for Expert-Autonomy.ps1 — the single guard deciding when the autonomous run must
    stop for the human. Autonomy brakes ONLY on the irreversible; everything else proceeds.
    Fail-safe: an UNKNOWN action is treated as irreversible (stop and ask), never waved through.
    Pure behind ABIOS_EXPERTAUTONOMY_DOTSOURCE. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-Autonomy.ps1' | Resolve-Path
    $env:ABIOS_EXPERTAUTONOMY_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTAUTONOMY_DOTSOURCE = ''
    $script:Default = @{ autonomy = @{ irreversible = @('merge','deploy','refresh','publish','delete') } }
}

Describe 'Test-IsIrreversible' {
    It 'brakes on merge' { Test-IsIrreversible -Action 'merge' -Contract $script:Default | Should -BeTrue }
    It 'brakes on deploy' { Test-IsIrreversible -Action 'deploy' -Contract $script:Default | Should -BeTrue }
    It 'brakes on delete' { Test-IsIrreversible -Action 'delete' -Contract $script:Default | Should -BeTrue }
    It 'proceeds on open-pr' { Test-IsIrreversible -Action 'open-pr' -Contract $script:Default | Should -BeFalse }
    It 'proceeds on create-issue' { Test-IsIrreversible -Action 'create-issue' -Contract $script:Default | Should -BeFalse }
    It 'proceeds on research' { Test-IsIrreversible -Action 'research' -Contract $script:Default | Should -BeFalse }
    It 'is case-insensitive' { Test-IsIrreversible -Action 'MERGE' -Contract $script:Default | Should -BeTrue }
    It 'fail-safe: an unknown action is treated as irreversible' {
        Test-IsIrreversible -Action 'frobnicate' -Contract $script:Default | Should -BeTrue
    }
    It 'honors a contract that adds a custom irreversible action' {
        $c = @{ autonomy = @{ irreversible = @('merge','custom-danger') } }
        Test-IsIrreversible -Action 'custom-danger' -Contract $c | Should -BeTrue
    }
    It 'a known-safe action stays safe even under a custom contract' {
        $c = @{ autonomy = @{ irreversible = @('merge') } }
        Test-IsIrreversible -Action 'build' -Contract $c | Should -BeFalse
    }
}
