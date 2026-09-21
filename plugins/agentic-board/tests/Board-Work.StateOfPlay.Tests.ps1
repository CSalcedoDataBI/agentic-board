#Requires -Modules Pester
<#  Tests for the "state of play" that /board work prints before its pending list (#660).

    Three layers, because each catches something the others cannot:
      1. the PURE classifiers, one source at a time, positives AND negatives (a finding invented
         over a healthy repo is as wrong as one missed over a sick one);
      2. Get-StateOfPlay over a REAL throwaway git repo - a real marker file, a real linked
         worktree, a real CHANGELOG and tag - with only the network edge (Invoke-Gh) faked. This is
         the regression the issue asks for: one repo seeded with all five kinds of open work must
         produce five findings;
      3. the WIRING: Board-Work.ps1 itself, run with a fake `gh` first on PATH, so the state of play
         is proven to print BEFORE the pending list and to never take the listing down. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    function New-Marker {
        param([int]$Epic = 491, [int[]]$Queue = @(493, 494, 495), [string]$Status = 'active', [string]$Updated = '2026-08-27T10:00:00Z')
        [pscustomobject]@{ epic = $Epic; board = 13; repo = 'o/r'; status = $Status; started = $Updated; updated = $Updated; queue = $Queue; entries = @() }
    }
    function New-Item2 {
        param([int]$Number, [string]$Status = '', [string]$Repo = 'o/r', [string]$Type = 'Issue')
        [pscustomobject]@{ status = $Status; title = "t$Number"; labels = @()
                           content = [pscustomobject]@{ type = $Type; number = $Number; title = "t$Number"; repository = $Repo } }
    }
    function New-OpenIssue {
        param([int]$Number, [int]$Total = 0, [int]$Completed = 0)
        [pscustomobject]@{ number = $Number; title = "issue $Number"; subIssuesSummary = [pscustomobject]@{ total = $Total; completed = $Completed } }
    }
}

Describe 'Get-RunMarkerFinding' {
    It 'is stale when the run is active but every queued issue is closed' {
        $f = Get-RunMarkerFinding -Marker (New-Marker) -OpenNumbers @(491, 7) -Verified $true
        $f.Group | Should -Be 'stale'
        $f.Text  | Should -Match '#493 #494 #495'
        $f.Offer | Should -Not -BeNullOrEmpty
    }
    It 'is stale when the epic itself is already closed and nothing of the queue is open' {
        (Get-RunMarkerFinding -Marker (New-Marker) -OpenNumbers @(7) -Verified $true).Group | Should -Be 'stale'
    }
    It 'does NOT offer to close a run whose epic is closed while its queue is still open' {
        $f = Get-RunMarkerFinding -Marker (New-Marker) -OpenNumbers @(493, 494) -Verified $true
        $f.Group | Should -Be 'inflight'
        $f.Offer | Should -BeNullOrEmpty
        $f.Text  | Should -Match '#493 #494'
    }
    It 'is IN FLIGHT while queued issues are still open, and says how many' {
        $f = Get-RunMarkerFinding -Marker (New-Marker) -OpenNumbers @(491, 494, 495) -Verified $true
        $f.Group | Should -Be 'inflight'
        $f.Text  | Should -Match '1 de 3'
        $f.Text  | Should -Match '#494 #495'
    }
    It 'is in flight, not stale, when the marker declares no queue and the epic is open' {
        (Get-RunMarkerFinding -Marker (New-Marker -Queue @()) -OpenNumbers @(491) -Verified $true).Group | Should -Be 'inflight'
    }
    It 'says nothing for a run already closed, or when there is no marker' {
        Get-RunMarkerFinding -Marker (New-Marker -Status 'closed') -OpenNumbers @() -Verified $true | Should -BeNullOrEmpty
        Get-RunMarkerFinding -Marker $null -OpenNumbers @() -Verified $true | Should -BeNullOrEmpty
    }
    It 'is UNKNOWN, never stale, when the open-issue list could not be read' {
        # An unread list looks exactly like "everything is closed"; concluding stale from it
        # would offer to close a run that is in fact running.
        (Get-RunMarkerFinding -Marker (New-Marker) -OpenNumbers @() -Verified $false).Group | Should -Be 'unknown'
    }
}

Describe 'Get-FinishedEpicFindings' {
    It 'flags an open epic whose sub-issues are all closed' {
        $f = @(Get-FinishedEpicFindings -OpenIssues @((New-OpenIssue 491 5 5)))
        $f.Count    | Should -Be 1
        $f[0].Group | Should -Be 'stale'
        $f[0].Text  | Should -Match '#491'
    }
    It 'does not flag an epic with a sub-issue still open' {
        @(Get-FinishedEpicFindings -OpenIssues @((New-OpenIssue 458 9 8))).Count | Should -Be 0
    }
    It 'does not treat a plain issue (no sub-issues) as a finished epic' {
        @(Get-FinishedEpicFindings -OpenIssues @((New-OpenIssue 12 0 0))).Count | Should -Be 0
    }
}

Describe 'Get-OffBoardFindings' {
    BeforeAll {
        $script:BoardItems = @((New-Item2 1 'Backlog'), (New-Item2 2 'Done'), (New-Item2 3 'In Progress'))
    }
    It 'lists open issues of the repo that are not on the board at all' {
        $f = @(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 1), (New-OpenIssue 9), (New-OpenIssue 8)) -Items $script:BoardItems -Repo 'o/r')
        $f.Count    | Should -Be 1
        $f[0].Group | Should -Be 'offboard'
        $f[0].Text  | Should -Match '#8 #9'
        $f[0].Text  | Should -Not -Match '#1\b'
    }
    It 'reports nothing when every open issue is on the board' {
        @(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 1), (New-OpenIssue 3)) -Items $script:BoardItems -Repo 'o/r').Count | Should -Be 0
    }
    It 'does not count a draft note or another repo item as putting the issue on the board' {
        $items = @((New-Item2 1 'Backlog'), (New-Item2 9 'Backlog' 'other/repo'), (New-Item2 8 'Backlog' 'o/r' 'DraftIssue'))
        $f = @(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 9), (New-OpenIssue 8)) -Items $items -Repo 'o/r')
        $f[0].Text | Should -Match '#8 #9'
    }
    It 'is UNKNOWN on a truncated board read - never a confident list' {
        (@(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 9)) -Items $script:BoardItems -Repo 'o/r' -BoardTruncated $true))[0].Group | Should -Be 'unknown'
    }
    It 'is UNKNOWN when the open-issue read failed' {
        (@(Get-OffBoardFindings -OpenIssues @() -Items $script:BoardItems -Repo 'o/r' -OpenVerified $false))[0].Group | Should -Be 'unknown'
    }
    It 'compares against a board with NO issues at all: every open issue is then off it' {
        $f = @(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 10), (New-OpenIssue 11)) -Items @() -Repo 'o/r')
        $f[0].Group | Should -Be 'offboard'
        $f[0].Text  | Should -Match '#10 #11'
    }
    It 'is skipped (not a false all-clear, not a false list) when the board tracks none of this repo' {
        $f = @(Get-OffBoardFindings -OpenIssues @((New-OpenIssue 9)) -Items @((New-Item2 1 'Backlog' 'other/repo')) -Repo 'o/r')
        $f[0].Group | Should -Be 'skipped'
    }
}

Describe 'Get-MergedWorktreeFindings' {
    It 'lists a worktree whose branch already merged' {
        $f = @(Get-MergedWorktreeFindings -Rows @([pscustomobject]@{ Path = 'C:/w/a'; Branch = 'issue-1-a'; Merged = $true; Pr = 5; Error = '' }))
        $f.Count    | Should -Be 1
        $f[0].Group | Should -Be 'stale'
        $f[0].Text  | Should -Match 'issue-1-a \(PR #5\)'
    }
    It 'never offers to clean a merged worktree that still holds uncommitted work, or whose state is unknown' {
        $rows = @(
            [pscustomobject]@{ Path = 'p1'; Branch = 'b-dirty'; Merged = $true; Pr = 5; Dirty = 'dirty'; Error = '' },
            [pscustomobject]@{ Path = 'p2'; Branch = 'b-unk';   Merged = $true; Pr = 6; Dirty = 'unknown'; Error = '' })
        $f = @(Get-MergedWorktreeFindings -Rows $rows)
        $f.Count | Should -Be 1
        $f[0].Offer | Should -BeNullOrEmpty
        $f[0].Text  | Should -Match 'b-dirty'
        $f[0].Text  | Should -Match 'b-unk'
    }
    It 'ignores a worktree whose branch is not merged' {
        @(Get-MergedWorktreeFindings -Rows @([pscustomobject]@{ Path = 'p'; Branch = 'b'; Merged = $false; Pr = 0; Error = '' })).Count | Should -Be 0
    }
    It 'leaves a branch a LIVE session still works out of the stale list' {
        @(Get-MergedWorktreeFindings -LiveBranches @('issue-1-a') -Rows @([pscustomobject]@{ Path = 'p'; Branch = 'issue-1-a'; Merged = $true; Pr = 5; Error = '' })).Count | Should -Be 0
    }
    It 'reports a worktree whose PR could not be read as UNKNOWN, not as merged or unmerged' {
        $f = @(Get-MergedWorktreeFindings -Rows @([pscustomobject]@{ Path = 'p'; Branch = 'b'; Merged = $false; Pr = 0; Error = 'boom' }))
        $f[0].Group | Should -Be 'unknown'
    }
}

Describe 'Get-UnreleasedFinding' {
    BeforeAll {
        $script:Cl = "# Changelog`r`n`r`n## [Unreleased]`r`n### Added`r`n- **one (#1).** text`r`n- **two (#2).** text`r`n### Fixed`r`n`r`n## [0.1.0] - 2026-01-01`r`n### Added`r`n- old`r`n"
    }
    It 'is due when [Unreleased] holds entries, and names the commits since the tag' {
        $f = Get-UnreleasedFinding -Delta ([pscustomobject]@{ Ok = $true; Text = $script:Cl; Tag = 'v0.1.0'; Commits = 8; BaseRef = 'origin/main'; Skipped = ''; Error = '' })
        $f.Group | Should -Be 'due'
        $f.Text  | Should -Match '2 entrada'
        $f.Text  | Should -Match '8 commit'
        $f.Text  | Should -Match 'v0\.1\.0'
    }
    It 'counts only what is under [Unreleased], not the released sections' {
        (Get-UnreleasedEntryCount $script:Cl).Entries | Should -Be 2
    }
    It 'says nothing when [Unreleased] is empty (commits alone are not a release)' {
        $empty = "## [Unreleased]`r`n### Added`r`n`r`n## [0.1.0] - 2026-01-01`r`n- old`r`n"
        Get-UnreleasedFinding -Delta ([pscustomobject]@{ Ok = $true; Text = $empty; Tag = 'v0.1.0'; Commits = 40; BaseRef = 'main'; Skipped = ''; Error = '' }) | Should -BeNullOrEmpty
    }
    It 'counts prose under [Unreleased] as content, so it cannot read as nothing to release' {
        (Get-UnreleasedEntryCount "## [Unreleased]`r`nSome note.`r`n## [0.1.0]`r`n").Entries | Should -Be 1
    }
    It 'is skipped for a repo with no CHANGELOG and UNKNOWN when the read failed' {
        (Get-UnreleasedFinding -Delta ([pscustomobject]@{ Ok = $false; Skipped = 'no changelog'; Error = '' })).Group | Should -Be 'skipped'
        (Get-UnreleasedFinding -Delta ([pscustomobject]@{ Ok = $false; Skipped = ''; Error = 'git died' })).Group     | Should -Be 'unknown'
    }
}

Describe 'Get-BoardInFlightFindings / Get-OpenPrFindings' {
    It 'reports In Progress and In Review items, including legacy vocabulary, but not drafts or Backlog' {
        $f = @(Get-BoardInFlightFindings -Items @((New-Item2 1 'In Progress'), (New-Item2 2 'In Review'), (New-Item2 3 'Backlog'),
                                                   (New-Item2 4 'Done'), (New-Item2 5 'In Progress' 'o/r' 'DraftIssue')))
        $f.Count   | Should -Be 1
        $f[0].Text | Should -Match '#1 #2'
        $f[0].Text | Should -Not -Match '#3|#4|#5'
    }
    It 'says nothing when nothing is in progress' {
        @(Get-BoardInFlightFindings -Items @((New-Item2 3 'Backlog'))).Count | Should -Be 0
    }
    It 'lists open PRs and marks a capped read as a floor' {
        $prs = @(1..3 | ForEach-Object { [pscustomobject]@{ number = $_; title = 't'; headRefName = "b$_"; isDraft = ($_ -eq 2) } })
        $f = @(Get-OpenPrFindings -Prs $prs)
        $f[0].Text | Should -Match '3 PR\(s\)'
        $f[0].Text | Should -Match 'borrador'
        (@(Get-OpenPrFindings -Prs $prs -Cap 3))[0].Text | Should -Match '3\+ PR'
    }
}

Describe 'Format-StateOfPlay' {
    It 'is ONE line when there is nothing to report' {
        $l = @(Format-StateOfPlay -Findings @())
        $l.Count   | Should -Be 1
        $l[0].Text | Should -Match 'sin novedades'
    }
    It 'a skipped source alone does not make the repo dirty' {
        $skip = New-StateFinding -Source 'x' -Group 'skipped' -Text 'no aplica'
        Test-StateOfPlayClean -Findings @($skip) | Should -BeTrue
    }
    It 'prints EVERY finding of every group (a loop variable must not clobber the list)' {
        # Regression: PowerShell variables are case-insensitive, so `foreach ($f in ...)` inside a
        # function whose list was called `$F` silently emptied it after the first group - the real
        # run showed "En curso" and lost the stale/off-board/due groups.
        $all = @(
            (New-StateFinding -Source 'a' -Group 'inflight' -Text 'AAA'),
            (New-StateFinding -Source 'b' -Group 'stale'    -Text 'BBB' -Offer 'do b'),
            (New-StateFinding -Source 'c' -Group 'offboard' -Text 'CCC' -Offer 'do c'),
            (New-StateFinding -Source 'd' -Group 'due'      -Text 'DDD' -Offer 'do d'),
            (New-StateFinding -Source 'e' -Group 'unknown'  -Text 'EEE'))
        $text = (@(Format-StateOfPlay -Findings $all -Repo 'o/r') | ForEach-Object Text) -join "`n"
        foreach ($x in 'AAA', 'BBB', 'CCC', 'DDD', 'EEE') { $text | Should -Match $x }
        $text | Should -Match 'Si quieres, lo hago yo: do b'
        $text | Should -Match 'no toco nada sin tu si'
    }
    It 'never prints a script name or a command for the user to run' {
        $all = @((New-StateFinding -Source 'b' -Group 'stale' -Text 'BBB' -Offer 'cerrar esa corrida'))
        $text = (@(Format-StateOfPlay -Findings $all) | ForEach-Object Text) -join "`n"
        $text | Should -Not -Match '\.ps1'
        $text | Should -Not -Match '(?m)^\s*(pwsh|git|gh)\s'
    }
}

Describe 'Read-StateOpenIssues' {
    It 'follows the cursor across pages, passing it as a GraphQL variable and never in the query text' {
        $script:Calls = @()
        Mock Invoke-Gh {
            $script:Calls += , @($GhArgs)
            $hasCursor = ($GhArgs -join ' ') -match 'cursor=CUR1'
            $nodes = if ($hasCursor) { @((New-OpenIssue 3)) } else { @((New-OpenIssue 1), (New-OpenIssue 2)) }
            [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ issues = [pscustomobject]@{
                pageInfo = [pscustomobject]@{ hasNextPage = (-not $hasCursor); endCursor = 'CUR1' }; nodes = $nodes } } } }
        }
        $r = Read-StateOpenIssues -Repo 'o/r'
        $r.Ok | Should -BeTrue
        @($r.Issues | ForEach-Object { $_.number }) | Should -Be @(1, 2, 3)
        $script:Calls.Count | Should -Be 2
        ($script:Calls[1] -contains 'cursor=CUR1') | Should -BeTrue
        (($script:Calls[1] | Where-Object { $_ -like 'query=*' }) -match 'CUR1') | Should -BeFalse
        ($script:Calls[0] -join ' ') | Should -Not -Match 'cursor='
    }
    It 'refuses to return a list that hit the page ceiling as if it were whole' {
        Mock Invoke-Gh {
            [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ issues = [pscustomobject]@{
                pageInfo = [pscustomobject]@{ hasNextPage = $true; endCursor = 'MORE' }; nodes = @((New-OpenIssue 1)) } } } }
        }
        $r = Read-StateOpenIssues -Repo 'o/r' -MaxPages 3
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'no leo la lista entera'
    }
    It 'turns a gh failure into a not-Ok result, not an exception' {
        Mock Invoke-Gh { throw 'HTTP 401' }
        $r = Read-StateOpenIssues -Repo 'o/r'
        $r.Ok    | Should -BeFalse
        $r.Error | Should -Match '401'
    }
}
Describe 'Get-StateOfPlay over a real repo (the five-finding regression)' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Push-Location $script:Root
        git init -q -b main 2>&1 | Out-Null
        git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
        Set-Content -LiteralPath CHANGELOG.md -Value "# Changelog`n`n## [0.1.0] - 2026-01-01`n### Added`n- old`n"
        git add CHANGELOG.md; git commit -q -m 'chore: first'; git update-ref refs/tags/v0.1.0 HEAD
        Set-Content -LiteralPath CHANGELOG.md -Value "# Changelog`n`n## [Unreleased]`n### Added`n- **new thing (#5).** text`n`n## [0.1.0] - 2026-01-01`n### Added`n- old`n"
        git add CHANGELOG.md; git commit -q -m 'feat: new thing (#5)'
        # A linked worktree on a branch whose PR (faked below) is MERGED at exactly this tip.
        $script:Wt = Join-Path $TestDrive 'repo-wt'
        git worktree add -q -b issue-9-done $script:Wt 2>&1 | Out-Null
        $script:WtTip = "$(git -C $script:Wt rev-parse HEAD)".Trim()
        # A second linked worktree whose PR is OPEN: must NOT be reported as merged.
        $script:Wt2 = Join-Path $TestDrive 'repo-wt2'
        git worktree add -q -b issue-10-open $script:Wt2 2>&1 | Out-Null
        $script:Wt2Tip = "$(git -C $script:Wt2 rev-parse HEAD)".Trim()
        # A third one whose branch NAME was reused: a MERGED PR exists, but for an OLDER tip.
        # A merge that does not cover these commits proves nothing about them.
        $script:Wt3 = Join-Path $TestDrive 'repo-wt3'
        git worktree add -q -b issue-11-reused $script:Wt3 2>&1 | Out-Null
        $script:MainTip = "$(git rev-parse main)".Trim()
        Pop-Location

        $script:State = Join-Path $script:Root '.agentic-board'
        New-Item -ItemType Directory -Path $script:State -Force | Out-Null
        (New-Marker) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:State 'active-run.json')

        $script:Items = @((New-Item2 100 'Backlog' 'o/r'))
    }

    BeforeEach {
        Mock Invoke-Gh {
            if ($GhArgs -contains 'graphql') {
                return [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ issues = [pscustomobject]@{
                    pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }
                    nodes = @(
                        (New-OpenIssue 100),               # on the board
                        (New-OpenIssue 200),               # NOT on the board  -> off-board
                        (New-OpenIssue 300 4 4),           # epic, all subs closed -> finished epic
                        (New-OpenIssue 491)                # the run's epic, queue (493..495) all closed -> stale run
                    ) } } } }
            }
            if ($GhArgs -contains 'pr' -and $GhArgs -contains '--head') {
                $branch = $GhArgs[[array]::IndexOf($GhArgs, '--head') + 1]
                if ($branch -eq 'issue-9-done')  { return @([pscustomobject]@{ number = 41; state = 'MERGED'; headRefOid = $script:WtTip }) }
                if ($branch -eq 'issue-10-open') { return @([pscustomobject]@{ number = 42; state = 'OPEN';   headRefOid = $script:Wt2Tip }) }
                # The MAIN working copy is never a candidate, even if a PR of its branch merged at its tip.
                if ($branch -eq 'main') { return @([pscustomobject]@{ number = 44; state = 'MERGED'; headRefOid = $script:MainTip }) }
                if ($branch -eq 'issue-12-broken' -and $script:Wt4Tip) { return @([pscustomobject]@{ number = 45; state = 'MERGED'; headRefOid = $script:Wt4Tip }) }
                if ($branch -eq 'issue-11-reused') { return @([pscustomobject]@{ number = 43; state = 'MERGED'; headRefOid = '0000000000000000000000000000000000000000' }) }
                return @()
            }
            if ($GhArgs -contains 'pr') { return @() }
            throw "unexpected gh call: $($GhArgs -join ' ')"
        }
    }

    It 'produces one finding for each of the five kinds of open work, and none for the healthy worktree' {
        Push-Location $script:Root
        try {
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally { Pop-Location }

        $bySource = @{}
        foreach ($x in $f) { if (-not $bySource.ContainsKey($x.Source)) { $bySource[$x.Source] = @() }; $bySource[$x.Source] += $x }
        $bySource['run'].Count      | Should -Be 1
        $bySource['run'][0].Group   | Should -Be 'stale'
        $bySource['epic'].Count     | Should -Be 1
        $bySource['epic'][0].Text   | Should -Match '#300'
        $bySource['worktree'].Count | Should -Be 1
        $bySource['worktree'][0].Text | Should -Match 'issue-9-done \(PR #41\)'
        $bySource['worktree'][0].Text | Should -Not -Match 'issue-10-open'
        $bySource['worktree'][0].Text | Should -Not -Match 'issue-11-reused'   # merged PR, but not for THIS tip
        $bySource['worktree'][0].Text | Should -Not -Match 'PR #44'            # the main working copy
        $bySource['offboard'].Count | Should -Be 1
        $bySource['offboard'][0].Text | Should -Match '#200'
        $bySource['release'].Count  | Should -Be 1
        $bySource['release'][0].Group | Should -Be 'due'
        $bySource['release'][0].Text  | Should -Match '1 commit'
        $bySource['release'][0].Text  | Should -Match 'v0\.1\.0'
        (@($f | Where-Object { $_.Group -in 'stale', 'offboard', 'due' })).Count | Should -Be 5
        Test-StateOfPlayClean -Findings $f | Should -BeFalse
    }

    It 'reads an untracked file in a merged worktree as live work and does not offer to clean it' {
        Set-Content -LiteralPath (Join-Path $script:Wt 'scratch.txt') -Value 'wip'
        Push-Location $script:Root
        try {
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally {
            Pop-Location
            Remove-Item -LiteralPath (Join-Path $script:Wt 'scratch.txt') -Force
        }
        $wt = @($f | Where-Object { $_.Source -eq 'worktree' })
        $wt.Count | Should -Be 1
        $wt[0].Offer | Should -BeNullOrEmpty
        $wt[0].Text  | Should -Match 'sin commitear'
        $wt[0].Text  | Should -Match 'issue-9-done'
    }

    It 'fails closed when git cannot tell whether a merged worktree is dirty' {
        $wt4 = Join-Path $TestDrive 'repo-wt4'
        Push-Location $script:Root
        try {
            git worktree add -q -b issue-12-broken $wt4 2>&1 | Out-Null
            $script:Wt4Tip = "$(git rev-parse issue-12-broken)".Trim()
            # A folder git cannot read: its `.git` link is garbage, so `git status` there fails.
            Set-Content -LiteralPath (Join-Path $wt4 '.git') -Value 'not a gitdir link'
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally {
            $script:Wt4Tip = $null
            Remove-Item -LiteralPath $wt4 -Recurse -Force -ErrorAction SilentlyContinue
            git worktree prune 2>&1 | Out-Null
            git branch -D issue-12-broken 2>&1 | Out-Null
            Pop-Location
        }
        $kept = @($f | Where-Object { $_.Source -eq 'worktree' -and $_.Text -match 'issue-12-broken' })
        $kept.Count | Should -Be 1
        $kept[0].Offer | Should -BeNullOrEmpty
        $kept[0].Text  | Should -Match 'sin commitear'
    }

    It 'never offers to remove the worktree the session is standing in, even when its own PR merged' {
        Push-Location $script:Wt
        try {
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally { Pop-Location }
        (@($f | Where-Object { $_.Source -eq 'worktree' })).Count | Should -Be 0
    }

    It 'without the live-session list it does not offer to clean any worktree (unknown instead)' {
        Push-Location $script:Root
        try {
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -LiveKnown $false -BaseRef 'main')
        } finally { Pop-Location }
        $wt = @($f | Where-Object { $_.Source -eq 'worktree' })
        $wt.Count | Should -Be 1
        $wt[0].Group | Should -Be 'unknown'
        $wt[0].Offer | Should -BeNullOrEmpty
    }

    It 'reports a clean repo as clean: same repo, nothing seeded' {
        $cleanRoot = Join-Path $TestDrive 'clean'
        New-Item -ItemType Directory -Path $cleanRoot -Force | Out-Null
        Push-Location $cleanRoot
        try {
            git init -q -b main 2>&1 | Out-Null
            git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
            Set-Content -LiteralPath CHANGELOG.md -Value "# Changelog`n`n## [Unreleased]`n`n## [0.1.0] - 2026-01-01`n- old`n"
            git add CHANGELOG.md; git commit -q -m 'chore: first'; git update-ref refs/tags/v0.1.0 HEAD
            Mock Invoke-Gh {
                if ($GhArgs -contains 'graphql') {
                    return [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ issues = [pscustomobject]@{
                        pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }; nodes = @((New-OpenIssue 100)) } } } }
                }
                return @()
            }
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir (Join-Path $cleanRoot '.agentic-board') -LiveBranches @() -BaseRef 'main')
        } finally { Pop-Location }
        Test-StateOfPlayClean -Findings $f | Should -BeTrue
        @(Format-StateOfPlay -Findings $f).Count | Should -Be 1
    }

    It 'a failed read of the open issues surfaces as UNKNOWN findings, never as an empty picture' {
        Mock Invoke-Gh { throw 'HTTP 401' }
        Push-Location $script:Root
        try {
            $f = @(Get-StateOfPlay -Repo 'o/r' -HereRepo 'o/r' -Items $script:Items -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally { Pop-Location }
        Test-StateOfPlayClean -Findings $f | Should -BeFalse
        # The active run must not be called stale off a list that could not be read.
        (@($f | Where-Object { $_.Source -eq 'run' }))[0].Group | Should -Be 'unknown'
        (@($f | Where-Object { $_.Group -eq 'stale' })).Count | Should -Be 0
    }

    It 'does not read this clone''s marker, worktrees or CHANGELOG when the repo is a different one' {
        Push-Location $script:Root
        try {
            $f = @(Get-StateOfPlay -Repo 'someone/else' -HereRepo 'o/r' -Items @() -BoardTruncated $false `
                                   -StateDir $script:State -LiveBranches @() -BaseRef 'main')
        } finally { Pop-Location }
        @($f | Where-Object { $_.Source -in 'run', 'worktree', 'release' }).Count | Should -Be 0
        (@($f | Where-Object { $_.Source -eq 'local' }))[0].Group | Should -Be 'skipped'
    }

    It 'says so when the marker file is corrupt instead of reading it as no run' {
        $bad = Join-Path $TestDrive 'badstate'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bad 'active-run.json') -Value '{ not json'
        (Read-StateRunMarker -StateDir $bad).Ok | Should -BeFalse
    }
}

Describe 'Board-Work.ps1 -ProjectNum prints the state of play before the pending list' -Tag 'Wired' {
    BeforeAll {
        # A fake `gh` FIRST on PATH: PowerShell resolves gh.ps1 before the real gh.exe, so the
        # script under test runs unmodified against canned GitHub answers.
        $script:Fake = Join-Path $TestDrive 'fakegh'
        New-Item -ItemType Directory -Path $script:Fake -Force | Out-Null
        $ghScript = @'
$a = @($args)
$line = $a -join ' '
function Out-Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
if ($env:FAKEGH_MODE -eq 'break-issues' -and $line -match 'graphql') { [Console]::Error.WriteLine('HTTP 500 boom'); exit 1 }
if ($line -match '^project item-list') {
    Out-Json ([pscustomobject]@{ totalCount = 2; items = @(
        [pscustomobject]@{ id = 'i1'; title = 'pending one'; status = 'Backlog'; labels = @(); content = [pscustomobject]@{ type = 'Issue'; number = 100; title = 'pending one'; repository = 'o/r' } },
        [pscustomobject]@{ id = 'i2'; title = 'active one';  status = 'In Progress'; labels = @(); content = [pscustomobject]@{ type = 'Issue'; number = 101; title = 'active one'; repository = 'o/r' } }) })
    exit 0
}
if ($line -match '^project field-list') { Out-Json ([pscustomobject]@{ fields = @() }); exit 0 }
if ($line -match 'graphql') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ issues = [pscustomobject]@{
        pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }
        nodes = @(
            [pscustomobject]@{ number = 100; title = 'pending one'; subIssuesSummary = [pscustomobject]@{ total = 0; completed = 0 } },
            [pscustomobject]@{ number = 101; title = 'active one';  subIssuesSummary = [pscustomobject]@{ total = 0; completed = 0 } },
            [pscustomobject]@{ number = 300; title = 'finished epic'; subIssuesSummary = [pscustomobject]@{ total = 2; completed = 2 } }) } } } })
    exit 0
}
if ($line -match '^pr list') { Write-Output '[]'; exit 0 }
[Console]::Error.WriteLine("fakegh: unexpected call: $line"); exit 1
'@
        Set-Content -LiteralPath (Join-Path $script:Fake 'gh.ps1') -Value $ghScript

        $script:Repo2 = Join-Path $TestDrive 'wired'
        New-Item -ItemType Directory -Path $script:Repo2 -Force | Out-Null
        Push-Location $script:Repo2
        git init -q -b main 2>&1 | Out-Null
        git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
        git remote add origin https://github.com/o/r.git
        Set-Content -LiteralPath README.md -Value 'x'
        git add README.md; git commit -q -m 'chore: first'
        Pop-Location

        function Invoke-Wired {
            param([string]$Mode = '')
            $savedPath = $env:PATH; $savedTok = $env:GH_TOKEN; $savedMode = $env:FAKEGH_MODE
            $env:PATH = "$($script:Fake)$([IO.Path]::PathSeparator)$savedPath"
            $env:GH_TOKEN = 'fake-token'; $env:FAKEGH_MODE = $Mode
            try {
                Push-Location $script:Repo2
                $out = pwsh -NoProfile -File $script:Script -ProjectNum 13 -Owner o 2>&1 | Out-String
                Pop-Location
                $out
            } finally { $env:PATH = $savedPath; $env:GH_TOKEN = $savedTok; $env:FAKEGH_MODE = $savedMode }
        }
    }

    It 'opens with the state of play and only then lists the pending items' {
        $out = Invoke-Wired
        $out | Should -Match 'Estado del trabajo \(o/r\)'
        $out | Should -Match 'epic #300'
        $out | Should -Match 'en progreso o en review: #101'
        $out | Should -Match 'Total: 1 pendiente'
        $out.IndexOf('Estado del trabajo') | Should -BeLessThan $out.IndexOf('Total: 1 pendiente')
        $out.IndexOf('Estado del trabajo') | Should -BeLessThan $out.IndexOf('#100')
    }

    It 'a corrupt sessions.json is reported as unknown, not read as no live sessions' {
        $dir = Join-Path $script:Repo2 '.agentic-board'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'sessions.json') -Value '{ not json'
        try { $out = Invoke-Wired } finally { Remove-Item -LiteralPath (Join-Path $dir 'sessions.json') -Force }
        $out | Should -Match 'No pude leer el registro de sesiones vivas'
        $out | Should -Match 'Total: 1 pendiente'
    }

    It 'never takes the pending list down when the state of play cannot read GitHub' {
        $out = Invoke-Wired -Mode 'break-issues'
        $out | Should -Match 'No pude leer los issues abiertos'
        $out | Should -Match 'Total: 1 pendiente'
    }
}
