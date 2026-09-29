#Requires -Modules Pester
<#  Pester tests for Board-CloseCycleSweep.ps1 - `/board close-cycle --all` (#734).

    The sweep closes every session on the machine, not only the current branch, and leaves
    nothing dangling: each branch gets ONE disposition, and each host-app session is archived
    only when the work behind it is resolved. These are the pure halves - every fact is an
    argument - so the rules are asserted without git, gh or a running app. #>

BeforeAll {
    $env:ABIOS_SWEEP_DOTSOURCE = '1'
    try { . (Join-Path $PSScriptRoot '..' 'scripts' 'Board-CloseCycleSweep.ps1' | Resolve-Path) }
    finally { $env:ABIOS_SWEEP_DOTSOURCE = '' }

    function script:Act {
        param([string]$Class = 'working', [string]$Dirty = 'clean', [bool]$Live = $false, [bool]$Open = $false, [int]$Ahead = 1)
        Get-SweepItemAction -Class $Class -Dirty $Dirty -HasLiveSession $Live -SessionOpen $Open -CommitsAhead $Ahead
    }
}

Describe 'Get-SweepItemAction - one disposition per branch' {
    It 'never touches a branch whose session is still working (registry or host app)' {
        (script:Act -Class 'merged' -Live $true).Action | Should -Be 'skip-open'
        (script:Act -Class 'merged' -Open $true).Action | Should -Be 'skip-open'
        (script:Act -Class 'merged' -Open $true).Resolved | Should -BeFalse
    }
    It 'tears down a proven-merged branch, and counts it as resolved' {
        $a = script:Act -Class 'merged'
        $a.Action | Should -Be 'teardown'
        $a.Resolved | Should -BeTrue
    }
    It 'parks committed work with no PR as a draft PR instead of leaving it local' {
        (script:Act -Class 'working' -Ahead 3).Action | Should -Be 'park'
        (script:Act -Class 'stale' -Ahead 1).Action | Should -Be 'park'
        (script:Act -Class 'stale' -Ahead 1).Resolved | Should -BeTrue
    }
    It 'parks commits made after a merge - that work is on no branch main knows about' {
        (script:Act -Class 'merged-advanced').Action | Should -Be 'park'
    }
    It 'commits uncommitted work first, then parks it - never loses it, never deletes it' {
        (script:Act -Class 'dirty' -Dirty 'dirty').Action | Should -Be 'wip-park'
        (script:Act -Class 'merged' -Dirty 'dirty').Action | Should -Be 'wip-park'
        (script:Act -Class 'in-review' -Dirty 'dirty').Action | Should -Be 'wip-park'
    }
    It 'asks a human when the worktree state cannot be read (fail closed)' {
        $a = script:Act -Class 'working' -Dirty 'unknown'
        $a.Action | Should -Be 'needs-decision'
        $a.Resolved | Should -BeFalse
    }
    It 'leaves an open PR alone - it is already visible - and counts it as resolved' {
        $a = script:Act -Class 'in-review'
        $a.Action | Should -Be 'keep-review'
        $a.Resolved | Should -BeTrue
    }
    It 'pushes an open PR''s branch that has commits the PR does not have yet' {
        # The host's archive tool removes the session's worktree; unpushed commits would go with it.
        $a = Get-SweepItemAction -Class 'in-review' -Unpushed 2
        $a.Action | Should -Be 'park'
        $a.Reason | Should -Match 'not pushed'
        (Get-SweepItemAction -Class 'in-review' -Unpushed 0).Action | Should -Be 'keep-review'
    }
    It 'treats an unknown unpushed count on an open PR as a question' {
        (Get-SweepItemAction -Class 'in-review' -Unpushed -1).Action | Should -Be 'needs-decision'
    }
    It 'never decides for the human on a PR closed without merging' {
        (script:Act -Class 'closed-unmerged').Action | Should -Be 'needs-decision'
        (script:Act -Class 'closed-unmerged' -Dirty 'dirty').Action | Should -Be 'needs-decision'
    }
    It 'deletes a clean branch with nothing on it - there is no work to lose' {
        (script:Act -Class 'stale' -Ahead 0).Action | Should -Be 'delete-empty'
        (script:Act -Class 'working' -Ahead 0).Resolved | Should -BeTrue
    }
    It 'treats an unknown commit count as a question, not as an empty branch' {
        (script:Act -Class 'stale' -Ahead -1).Action | Should -Be 'needs-decision'
    }
    It 'never pushes or opens a PR in a repo of another account - that becomes a decision' {
        # Measured on the real sweep: a client repo readable by the personal token would have
        # received a 70-commit draft PR under the personal identity.
        $a = Get-SweepItemAction -Class 'working' -CommitsAhead 70 -ForeignOwner 'SomeCompany'
        $a.Action | Should -Be 'needs-decision'
        $a.Reason | Should -Match 'SomeCompany'
        (Get-SweepItemAction -Class 'dirty' -Dirty 'dirty' -ForeignOwner 'SomeCompany').Action | Should -Be 'needs-decision'
    }
    It 'still does the purely local cleanup in a repo of another account' {
        (Get-SweepItemAction -Class 'merged' -ForeignOwner 'SomeCompany').Action | Should -Be 'teardown'
        (Get-SweepItemAction -Class 'stale' -CommitsAhead 0 -ForeignOwner 'SomeCompany').Action | Should -Be 'delete-empty'
        (Get-SweepItemAction -Class 'in-review' -ForeignOwner 'SomeCompany').Action | Should -Be 'keep-review'
    }
    It 'every disposition says why, in words' {
        foreach ($c in 'merged', 'merged-advanced', 'in-review', 'closed-unmerged', 'active', 'dirty', 'stale', 'working') {
            (script:Act -Class $c).Reason | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-SweepArchiveVerdict - archive a session only when nothing is left behind it' {
    BeforeAll {
        $script:Now = [datetime]'2026-09-29T12:00:00Z'
        $script:Items = @(
            [pscustomobject]@{ RepoRoot = 'D:\r\app'; WorktreePath = 'D:\r\app\.claude\worktrees\a'; Branch = 'issue-1-a'; Action = 'teardown';       Resolved = $true;  Reason = 'merged' }
            [pscustomobject]@{ RepoRoot = 'D:\r\app'; WorktreePath = 'D:\r\app\.claude\worktrees\b'; Branch = 'issue-2-b'; Action = 'needs-decision'; Resolved = $false; Reason = 'PR closed without merging' }
            [pscustomobject]@{ RepoRoot = 'D:\r\app'; WorktreePath = 'D:\r\app\.claude\worktrees\c'; Branch = 'issue-3-c'; Action = 'park';           Resolved = $true;  Reason = 'parked' }
        )
        function script:Verdict {
            param($Session, [scriptblock]$IsGitRepo = { param($p) $false }, [scriptblock]$PathExists = { param($p) $true })
            Get-SweepArchiveVerdict -Session $Session -Items $script:Items -ScannedRoots @('D:\r\app') `
                -IdleDays 7 -Now $script:Now -IsGitRepo $IsGitRepo -PathExists $PathExists
        }
        function script:S {
            param([string]$Cwd, [bool]$Running = $false, [int]$DaysIdle = 30, [bool]$Pinned = $false)
            [pscustomobject]@{ sessionId = 'local_x'; title = 't'; cwd = $Cwd; isRunning = $Running
                lastActivityAt = $script:Now.AddDays(-$DaysIdle).ToString('o'); pinned = $Pinned }
        }
    }
    It 'keeps a session that is still running, whatever its branch says' {
        $v = script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\a' -Running $true)
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'running|corriendo'
    }
    It 'keeps a pinned session' {
        (script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\a' -Pinned $true)).Archive | Should -BeFalse
    }
    It 'archives the session of a torn-down branch' {
        (script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\a' -DaysIdle 0)).Archive | Should -BeTrue
    }
    It 'archives the session of a parked branch, and names the branch it parked' {
        $v = script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\c' -DaysIdle 0)
        $v.Archive | Should -BeTrue
        $v.Branch | Should -Be 'issue-3-c'
    }
    It 'keeps the session of a branch that still needs a decision, with the reason' {
        $v = script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\b')
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'closed without merging'
    }
    It 'matches paths case- and slash-insensitively' {
        (script:Verdict (script:S -Cwd 'd:/R/APP/.claude/worktrees/A/' -DaysIdle 0)).Archive | Should -BeTrue
    }
    It 'archives an idle session on the repo root (nothing tied to a branch) only after IdleDays' {
        (script:Verdict (script:S -Cwd 'D:\r\app' -DaysIdle 30)).Archive | Should -BeTrue
        (script:Verdict (script:S -Cwd 'D:\r\app' -DaysIdle 2)).Archive | Should -BeFalse
    }
    It 'archives a session whose worktree is already gone - there is no work left to lose' {
        $v = script:Verdict (script:S -Cwd 'D:\r\app\.claude\worktrees\gone' -DaysIdle 0) -PathExists { param($p) $false }
        $v.Archive | Should -BeTrue
    }
    It 'keeps a session in a git repo this sweep did not scan - its pending work is unknown' {
        $v = script:Verdict (script:S -Cwd 'E:\other\repo') -IsGitRepo { param($p) $true }
        $v.Archive | Should -BeFalse
        $v.Reason | Should -Match 'not scanned|no se escaneo'
    }
    It 'reads a lastActivityAt that ConvertFrom-Json already turned into a DateTime, whatever the culture' {
        # Measured on the real session list (es-CO): the DateTime stringified as 09/10/2026 and was
        # re-parsed day-first, so 10 September became 9 October and "idle" came out negative.
        $prev = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'es-CO'
            $s = script:S -Cwd 'D:\r\app' -DaysIdle 0
            $s.lastActivityAt = [datetime]::SpecifyKind([datetime]'2026-09-10T18:55:22', 'Utc')
            $v = script:Verdict $s
            $v.Archive | Should -BeTrue -Because '19 days idle is past the 7-day threshold'
            $v.Reason | Should -Match 'idle 18|idle 19'
        } finally { [cultureinfo]::CurrentCulture = $prev }
    }
    It 'says a session''s folder is gone rather than calling it "outside any repo"' {
        $v = script:Verdict (script:S -Cwd 'E:\moved\repo' -DaysIdle 0) -PathExists { param($p) $false }
        $v.Archive | Should -BeTrue
        $v.Reason | Should -Match 'no longer exists'
    }
    It 'archives an idle session outside any git repo after IdleDays' {
        (script:Verdict (script:S -Cwd 'C:\Users\me\notes' -DaysIdle 30)).Archive | Should -BeTrue
        (script:Verdict (script:S -Cwd 'C:\Users\me\notes' -DaysIdle 1)).Archive | Should -BeFalse
    }
}

Describe 'Select-SweepSessions - run it from one repo without touching the others' {
    <#  The product owner's rule: never interfere with repos and sessions being worked elsewhere.
        Each repo runs its own sweep; the sessions no repo owns any more are a separate scope. #>
    BeforeAll {
        $script:Sessions = @(
            [pscustomobject]@{ sessionId = 'here-root'; cwd = 'D:\r\app' }
            [pscustomobject]@{ sessionId = 'here-wt';   cwd = 'D:\r\app\.claude\worktrees\a' }
            [pscustomobject]@{ sessionId = 'here-gone'; cwd = 'D:\r\app\.claude\worktrees\gone' }
            [pscustomobject]@{ sessionId = 'other';     cwd = 'D:\r\other' }
            [pscustomobject]@{ sessionId = 'moved';     cwd = 'E:\old\app' }
            [pscustomobject]@{ sessionId = 'home';      cwd = 'C:\Users\me' }
        )
        $script:Main = { param($p) switch -Regex ($p) { '^D:\\r\\app(\\\.claude\\worktrees\\a)?$' { 'D:\r\app' } '^D:\\r\\other$' { 'D:\r\other' } default { '' } } }
        $script:Exists = { param($p) $p -notin @('D:\r\app\.claude\worktrees\gone', 'E:\old\app') }
        function script:Pick([string]$Scope) {
            @(Select-SweepSessions -Sessions $script:Sessions -Scope $Scope -RepoRoot 'D:\r\app' -MainRepoOf $script:Main -PathExists $script:Exists).sessionId
        }
    }
    It 'repo: only the sessions of this repo, including its worktrees and its vanished worktrees' {
        script:Pick 'repo' | Should -Be @('here-root', 'here-wt', 'here-gone')
    }
    It 'orphans: only sessions whose folder is gone or that sit outside any repo' {
        script:Pick 'orphans' | Should -Be @('moved', 'home')
    }
    It 'orphans never includes a session of an existing repo - those belong to that repo''s own sweep' {
        script:Pick 'orphans' | Should -Not -Contain 'other'
        script:Pick 'orphans' | Should -Not -Contain 'here-root'
    }
    It 'all: every session' {
        (script:Pick 'all').Count | Should -Be 6
    }
}

Describe 'New-ParkedPrBody - the draft PR is how main learns the branch exists' {
    It 'refers to the issue from the branch name WITHOUT a closing keyword' {
        $b = New-ParkedPrBody -Branch 'issue-42-fix-x' -Reason 'commits without a PR'
        $b | Should -Match 'Refs #42'
        $b | Should -Not -Match '(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?) #42'
    }
    It 'links the session that worked the branch when it is known' {
        $b = New-ParkedPrBody -Branch 'feature-y' -Reason 'r' -SessionTitle 'My session' -SessionLink 'claude://x/local_1'
        $b | Should -Match 'My session'
        $b | Should -Match 'claude://x/local_1'
    }
    It 'says how to resume it' {
        New-ParkedPrBody -Branch 'feature-y' -Reason 'r' | Should -Match '/board work'
    }
}
