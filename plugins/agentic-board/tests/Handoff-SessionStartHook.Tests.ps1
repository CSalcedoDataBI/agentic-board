#Requires -Modules Pester
<#  Pester tests for Handoff-SessionStartHook.ps1 - the opt-in SessionStart hook.

    The hook reads stdin and touches the filesystem, so it exposes a dot-source guard:
    with $env:ABIOS_HANDOFF_HOOK_DOTSOURCE set it returns after defining the pure
    Get-HandoffSessionContext helper, without reading stdin. These tests exercise only
    that helper. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Handoff-SessionStartHook.ps1' | Resolve-Path
    $env:ABIOS_HANDOFF_HOOK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_HOOK_DOTSOURCE = ''

    $script:Full = @'
---
issue: 141
repo: o/r
branch: issue-141-x
pr: 148
board: 13
saved: 2026-07-07T19:13:47Z
host: H
verified: 6/6
---
# Handoff - #141
## Next concrete step
[V] wire the SessionStart hook
## Traps / failed approaches (do NOT repeat)
- [V] something
'@
}

Describe 'Get-HandoffSessionContext' {
    It 'returns empty for an empty body' {
        Get-HandoffSessionContext '' | Should -BeExactly ''
    }
    It 'names the issue and saved time' {
        $c = Get-HandoffSessionContext $script:Full
        $c | Should -Match 'issue #141'
        $c | Should -Match 'saved 2026-07-07T19:13:47Z'
    }
    It 'quotes the next step with the [V]/[?] tag stripped' {
        $c = Get-HandoffSessionContext $script:Full
        $c | Should -Match 'Next step: wire the SessionStart hook'
        $c | Should -Not -Match '\[V\] wire'
    }
    It 'always points at Board-Handoff.ps1 -Resume' {
        Get-HandoffSessionContext $script:Full | Should -Match 'Board-Handoff\.ps1 -Resume'
    }
    It 'does not double the period when the next step already ends with one' {
        $b = "---`nissue: 5`nsaved: 2026-01-01T00:00:00Z`n---`n## Next concrete step`n[V] do the thing."
        Get-HandoffSessionContext $b | Should -Not -Match 'thing\.\.'
    }
    It 'falls back to "this repo" when issue is null' {
        $b = "---`nissue: null`nsaved: 2026-01-01T00:00:00Z`n---`n# Handoff"
        $c = Get-HandoffSessionContext $b
        $c | Should -Match 'for this repo'
        $c | Should -Not -Match 'issue #null'
    }
    It 'omits the "Next step" clause when there is no such section' {
        $b = "---`nissue: 9`nsaved: 2026-01-01T00:00:00Z`n---`n# Handoff`nno next section here"
        $c = Get-HandoffSessionContext $b
        $c | Should -Not -Match 'Next step:'
        $c | Should -Match 'issue #9'
    }
}

Describe 'Get-CompactSessionContext' {
    It 'returns empty for a null marker' {
        Get-CompactSessionContext $null | Should -BeExactly ''
    }
    It 'returns empty when the run is not active (strict no-op off-run)' {
        $m = [pscustomobject]@{ epic = 348; board = 13; repo = 'o/r'; status = 'closed' }
        Get-CompactSessionContext $m | Should -BeExactly ''
    }
    It 'returns empty when there is no epic' {
        $m = [pscustomobject]@{ board = 13; repo = 'o/r'; status = 'active' }
        Get-CompactSessionContext $m | Should -BeExactly ''
    }
    It 'names the epic and points at the [abios-run-ledger] comment' {
        $m = [pscustomobject]@{ epic = 348; board = 13; repo = 'o/r'; status = 'active'; queue = @(349, 350) }
        $c = Get-CompactSessionContext $m
        $c | Should -Match 'epic #348'
        $c | Should -Match 'board #13'
        $c | Should -Match 'abios-run-ledger'
        $c | Should -Match 'gh issue view 348 --comments'
        $c | Should -Match '#349, #350'
    }
    It 'omits the board clause when the board is unknown' {
        $m = [pscustomobject]@{ epic = 5; board = 0; repo = 'o/r'; status = 'active' }
        $c = Get-CompactSessionContext $m
        $c | Should -Match 'epic #5'
        $c | Should -Not -Match 'board #0'
    }
    It 'tells the agent to re-read live status from the board' {
        $m = [pscustomobject]@{ epic = 1; board = 2; repo = 'o/r'; status = 'active' }
        Get-CompactSessionContext $m | Should -Match 'status from the board'
    }
}
