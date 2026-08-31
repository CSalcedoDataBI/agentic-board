#Requires -Modules Pester
<#  Pester tests for Fleet-Handoff.ps1 - dependency-aware hand-off (P3-4). A dependent
    issue waits for its blockers' PRs to merge, and inherits the upstream findings as
    context. Pure core (readiness + context) behind a dot-source guard
    ($env:ABIOS_FLEETHANDOFF_DOTSOURCE); only the CLI touches gh / the blackboard. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Handoff.ps1' | Resolve-Path
    $env:ABIOS_FLEETHANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FLEETHANDOFF_DOTSOURCE = ''

    function New-Find {
        param([int]$Issue, [string[]]$Decisions = @(), [string[]]$Gotchas = @(), [string[]]$Files = @())
        [pscustomobject]@{ issue = $Issue; decisions = $Decisions; gotchas = $Gotchas; filesTouched = $Files; pr = ''; status = 'done' }
    }
}

Describe 'Get-PendingBlockers' {
    It 'returns empty when there are no blockers' {
        @(Get-PendingBlockers @() @{}).Count | Should -Be 0
    }
    It 'returns empty when every blocker is merged' {
        @(Get-PendingBlockers @(1,2) @{ 1 = $true; 2 = $true }).Count | Should -Be 0
    }
    It 'returns the blockers that are not yet merged' {
        Get-PendingBlockers @(1,2,3) @{ 1 = $true; 3 = $true } | Should -Be @(2)
    }
    It 'treats a blocker absent from the lookup as pending (unknown = not merged)' {
        Get-PendingBlockers @(9) @{} | Should -Be @(9)
    }
}

Describe 'Get-HandoffContext' {
    It 'is empty when the issue has no blockers' {
        Get-HandoffContext @() @( (New-Find 1 -Decisions 'x') ) | Should -Be ''
    }
    It 'is empty when no blocker has a recorded finding' {
        Get-HandoffContext @(5) @( (New-Find 1 -Decisions 'x') ) | Should -Be ''
    }
    It 'summarizes an upstream blocker findings (decisions, gotchas, files)' {
        $ctx = Get-HandoffContext @(1) @( (New-Find 1 -Decisions 'used MSAL' -Gotchas 'watch pagination' -Files 'auth.ps1') )
        $ctx | Should -Match 'Upstream #1'
        $ctx | Should -Match 'used MSAL'
        $ctx | Should -Match 'watch pagination'
        $ctx | Should -Match 'auth\.ps1'
    }
    It 'includes only the blockers of this issue' {
        $ctx = Get-HandoffContext @(2) @( (New-Find 1 -Decisions 'a'), (New-Find 2 -Decisions 'b') )
        $ctx | Should -Match 'Upstream #2'
        $ctx | Should -Not -Match 'Upstream #1'
    }
}
