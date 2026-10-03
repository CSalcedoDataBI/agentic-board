#Requires -Modules Pester
<#  Tests for Assert-BoardComplete.ps1 — the "board is fully worked" pass/fail check.

    Side-effecting (reads the board over gh), so it exposes a dot-source guard: with
    $env:ABIOS_BOARDCOMPLETE_DOTSOURCE set it returns after defining the pure helpers (and the
    Get-BoardVocabulary it depends on). These tests pin the pending definition — it must match
    Board-Work's Test-Pending: empty Status OR a Status that MEANS Backlog (canonical or legacy 'Todo'),
    and nothing else. That is the exact rule that decides whether the board "quedó full". #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Assert-BoardComplete.ps1' | Resolve-Path
    $env:ABIOS_BOARDCOMPLETE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDCOMPLETE_DOTSOURCE = ''
    function script:Item($num, $status) { [pscustomobject]@{ content = [pscustomobject]@{ number = $num; title = "issue $num" }; status = $status } }
}

Describe 'Test-BoardItemPending (matches Board-Work Test-Pending)' {
    It 'an item with no Status is pending' { Test-BoardItemPending (Item 1 $null) | Should -BeTrue }
    It 'an empty-string Status is pending' { Test-BoardItemPending (Item 1 '') | Should -BeTrue }
    It 'Backlog is pending' { Test-BoardItemPending (Item 1 'Backlog') | Should -BeTrue }
    It "the legacy 'Todo' means Backlog, so it is pending" { Test-BoardItemPending (Item 1 'Todo') | Should -BeTrue }
    It 'In Progress is NOT pending (it was picked up)' { Test-BoardItemPending (Item 1 'In Progress') | Should -BeFalse }
    It 'In Review is NOT pending' { Test-BoardItemPending (Item 1 'In Review') | Should -BeFalse }
    It 'Done is NOT pending' { Test-BoardItemPending (Item 1 'Done') | Should -BeFalse }
    It 'Blocked is NOT pending (started, just stuck)' { Test-BoardItemPending (Item 1 'Blocked') | Should -BeFalse }
}

Describe 'Get-BoardCompletion (the pass/fail verdict)' {
    It 'is COMPLETE when every item is Done / In Review / In Progress' {
        $r = Get-BoardCompletion @( (Item 1 'Done'), (Item 2 'In Review'), (Item 3 'In Progress') )
        $r.Complete | Should -BeTrue
        $r.PendingCount | Should -Be 0
    }
    It 'is COMPLETE on an empty board' {
        (Get-BoardCompletion @()).Complete | Should -BeTrue
    }
    It 'is NOT complete when a Backlog item remains, and lists it' {
        $r = Get-BoardCompletion @( (Item 5 'Done'), (Item 9 'Backlog'), (Item 7 'Todo') )
        $r.Complete | Should -BeFalse
        $r.PendingCount | Should -Be 2
        @($r.Pending.number) | Should -Be @(7, 9)   # sorted by number; both Backlog-ish
    }
    It 'counts an item with no Status as pending' {
        (Get-BoardCompletion @( (Item 1 $null) )).PendingCount | Should -Be 1
    }
}
