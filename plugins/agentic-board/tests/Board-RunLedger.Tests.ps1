#Requires -Modules Pester
<#  Pester tests for Board-RunLedger.ps1 - the run-ledger writer (epic #348).

    The script touches gh + the filesystem, so it exposes a dot-source guard: with
    $env:ABIOS_RUNLEDGER_DOTSOURCE set it returns after defining the pure helpers,
    without the token check or any side effect. These tests exercise only those
    helpers, with a FIXED clock so the stamps are deterministic. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-RunLedger.ps1' | Resolve-Path
    $env:ABIOS_RUNLEDGER_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_RUNLEDGER_DOTSOURCE = ''

    $script:T0 = [datetime]'2026-07-17T10:00:00Z'
    $script:T1 = [datetime]'2026-07-17T11:30:00Z'
}

Describe 'Get-RunLedgerStamp' {
    It 'emits RFC3339 UTC with a trailing Z' {
        Get-RunLedgerStamp $script:T0 | Should -BeExactly '2026-07-17T10:00:00Z'
    }
    It 'converts a local time to UTC' {
        $local = [datetime]::new(2026, 7, 17, 10, 0, 0, [System.DateTimeKind]::Local)
        Get-RunLedgerStamp $local | Should -Match 'Z$'
    }
}

Describe 'New-RunState' {
    It 'starts active with the queue and both timestamps set' {
        $s = New-RunState -Epic 348 -Board 13 -Repo 'o/r' -Queue 349,350 -When $script:T0
        $s.epic    | Should -Be 348
        $s.board   | Should -Be 13
        $s.repo    | Should -BeExactly 'o/r'
        $s.status  | Should -BeExactly 'active'
        $s.started | Should -BeExactly '2026-07-17T10:00:00Z'
        $s.updated | Should -BeExactly '2026-07-17T10:00:00Z'
        @($s.queue).Count | Should -Be 2
        @($s.entries).Count | Should -Be 0
    }
    It 'tolerates an empty queue' {
        $s = New-RunState -Epic 1 -Board 0 -Repo 'o/r' -When $script:T0
        @($s.queue).Count | Should -Be 0
    }
}

Describe 'Add-RunEntry' {
    It 'appends an entry, bumps updated, and does not mutate the input' {
        $s0 = New-RunState -Epic 348 -Board 13 -Repo 'o/r' -Queue 349 -When $script:T0
        $s1 = Add-RunEntry -State $s0 -Issue 349 -Note 'reused Invoke-Gh' -Next 'wire the hook' -When $script:T1
        @($s0.entries).Count | Should -Be 0            # input untouched
        @($s1.entries).Count | Should -Be 1
        $s1.entries[0].issue | Should -Be 349
        $s1.entries[0].note  | Should -BeExactly 'reused Invoke-Gh'
        $s1.entries[0].next  | Should -BeExactly 'wire the hook'
        $s1.entries[0].at    | Should -BeExactly '2026-07-17T11:30:00Z'
        $s1.updated          | Should -BeExactly '2026-07-17T11:30:00Z'
        $s1.started          | Should -BeExactly '2026-07-17T10:00:00Z'   # preserved
    }
    It 'is a log, not a set - the same issue can appear twice' {
        $s = New-RunState -Epic 1 -Board 0 -Repo 'o/r' -When $script:T0
        $s = Add-RunEntry -State $s -Issue 5 -Note 'a' -When $script:T0
        $s = Add-RunEntry -State $s -Issue 5 -Note 'b' -When $script:T1
        @($s.entries).Count | Should -Be 2
    }
}

Describe 'Format-RunLedgerComment' {
    It 'carries the hidden marker and the visible tag' {
        $s = New-RunState -Epic 348 -Board 13 -Repo 'o/r' -Queue 349,350 -When $script:T0
        $body = Format-RunLedgerComment $s
        $body | Should -Match '<!-- abios-run-ledger -->'
        $body | Should -Match '\[abios-run-ledger\]'
        $body | Should -Match 'epic #348'
        $body | Should -Match 'Board #13'
    }
    It 'lists the queue as #-prefixed numbers' {
        $s = New-RunState -Epic 1 -Board 2 -Repo 'o/r' -Queue 349,350,351 -When $script:T0
        Format-RunLedgerComment $s | Should -Match '#349, #350, #351'
    }
    It 'renders a table row per entry once entries exist' {
        $s = New-RunState -Epic 1 -Board 2 -Repo 'o/r' -Queue 349 -When $script:T0
        $s = Add-RunEntry -State $s -Issue 349 -Note 'did X' -Next 'do Y' -When $script:T1
        $body = Format-RunLedgerComment $s
        $body | Should -Match '\| issue \| note \| next \|'
        $body | Should -Match '\| #349 \| did X \| do Y \|'
    }
    It 'omits the table when there are no entries yet' {
        $s = New-RunState -Epic 1 -Board 2 -Repo 'o/r' -When $script:T0
        Format-RunLedgerComment $s | Should -Not -Match '\| issue \| note \| next \|'
    }
    It 'reflects the closed status' {
        $s = New-RunState -Epic 1 -Board 2 -Repo 'o/r' -When $script:T0
        $s.status = 'closed'
        Format-RunLedgerComment $s | Should -Match 'Status:\*\* closed'
    }
}
