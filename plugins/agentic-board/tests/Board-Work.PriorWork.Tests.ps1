#Requires -Modules Pester
<#  Pester tests for the prior-work guard of Board-Work.ps1 -Start (#507, #471, #502) and the
    pending-list title (#522).

    The existing tests of the guard MOCK Get-IssueLinkedWork, so nothing exercised the real
    match. These drive the REAL Get-IssueLinkedWork + Get-PriorWorkRefusal end to end; the only
    thing replaced is the gh transport (Invoke-GhRaw), and the commit hits it returns are built
    from a REAL git history, so the message a test asserts on is the message git recorded. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    # ---- a throw-away git repo whose log stands in for `gh search commits` ----------------
    $script:Repo = Join-Path ([IO.Path]::GetTempPath()) ("priorwork-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Repo | Out-Null
    git -C $script:Repo init --quiet 2>&1 | Out-Null
    git -C $script:Repo config user.email 't@example.com'
    git -C $script:Repo config user.name  't'
    git -C $script:Repo config commit.gpgsign false
    $script:Clock = [datetimeoffset]'2026-01-01T10:00:00+00:00'

    # Commit an empty change with a controlled date; returns the sha. $Message may be multi-line.
    function Add-FixtureCommit([string]$Message) {
        $script:Clock = $script:Clock.AddHours(1)
        $iso = $script:Clock.ToString('yyyy-MM-ddTHH:mm:ssK')
        $env:GIT_AUTHOR_DATE = $iso; $env:GIT_COMMITTER_DATE = $iso
        $f = Join-Path $script:Repo 'msg.txt'
        [IO.File]::WriteAllText($f, $Message)
        git -C $script:Repo commit --allow-empty --quiet -F $f 2>&1 | Out-Null
        $env:GIT_AUTHOR_DATE = $null; $env:GIT_COMMITTER_DATE = $null
        return (git -C $script:Repo rev-parse HEAD).Trim()
    }

    # `gh search commits --json sha,commit` shape, produced from the real log.
    function Get-FixtureHits {
        $raw = git -C $script:Repo log --format='%H%x1f%cI%x1f%B%x1e'
        $hits = foreach ($rec in (($raw -join "`n") -split [char]0x1e)) {
            if (-not $rec.Trim()) { continue }
            $p = $rec.Trim("`n") -split [char]0x1f, 3
            [ordered]@{ sha = $p[0]; commit = [ordered]@{ message = $p[2].TrimEnd(); committer = [ordered]@{ date = $p[1] } } }
        }
        return (ConvertTo-Json @($hits) -Depth 6 -Compress)
    }

    # Run the REAL Get-IssueLinkedWork for $Issue with gh answering from the fixture.
    function Get-LinkedFor([int]$Issue, [string]$PrNodesJson = '[]') {
        $script:PrJson   = $PrNodesJson
        $script:HitsJson = Get-FixtureHits
        Get-IssueLinkedWork 'o/r' $Issue
    }
}

AfterAll {
    if ($script:Repo -and (Test-Path $script:Repo)) { Remove-Item $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'prior-work guard on a real git history (#507 #502 #471)' {
    BeforeEach {
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'graphql') {
                return [pscustomobject]@{ ExitCode = 0; StdErr = ''
                    Output = '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":' + $script:PrJson + '}}}}}' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdErr = ''; Output = $script:HitsJson }
        }
    }

    Context 'a (#n) that only appears in a commit BODY is prose, not a citation (#507, #502)' {
        BeforeAll {
            # The exact shape of the reported false positive: a dependency-bump merge whose body
            # carries a "Deferred" note naming another PR/issue number.
            $null = Add-FixtureCommit "chore(deps): bump eslint (#40)`n`nDeferred: @eslint/js 9->10 (#22) - requires a coordinated bump"
            $null = Add-FixtureCommit "feat(x): add the thing (#41)`n`nBoth remaining edges are spec-patcher, which is #23 - the module that`nRefs #24"
        }
        It 'does not treat a body mention of (#22) as work on issue 22' {
            $l = Get-LinkedFor 22
            @($l.commits).Count | Should -Be 0
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Be ''
        }
        It 'does not treat a bare #23 or a Refs #24 in the body as work either' {
            @((Get-LinkedFor 23).commits).Count | Should -Be 0
            @((Get-LinkedFor 24).commits).Count | Should -Be 0
        }
        It 'still finds the PR number that the subject really carries (that commit is about #40, not #22)' {
            @((Get-LinkedFor 40).commits).Count | Should -Be 1
        }
    }

    Context 'a subject that does cite the issue still refuses (the guard keeps its teeth)' {
        BeforeAll {
            $script:LandedSha = Add-FixtureCommit "fix(work): the real change (#50) (#88)`n`nbody"
        }
        It 'refuses on a `(#n)` in the subject, with the commit short sha' {
            $l = Get-LinkedFor 50
            @($l.commits).Count | Should -Be 1
            $l.commits[0].sha | Should -Be $script:LandedSha
            $r = Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt
            $r | Should -Match 'ya cita este issue'
            $r | Should -Match $script:LandedSha.Substring(0, 7)
        }
        It 'matches the exact number: (#5) is not (#50), (#500) is not (#50)' {
            @((Get-LinkedFor 5).commits).Count   | Should -Be 0
            $null = Add-FixtureCommit 'fix: other (#500)'
            @((Get-LinkedFor 50).commits).Count  | Should -Be 1
        }
        It 'accepts a GitHub closing keyword in the subject' {
            $null = Add-FixtureCommit 'fix(work): tidy up, closes #60'
            @((Get-LinkedFor 60).commits).Count | Should -Be 1
            $null = Add-FixtureCommit 'fix(work): tidy up, closes #610'
            @((Get-LinkedFor 61).commits).Count | Should -Be 0
        }
        It 'does not treat "Refs #n" / "Part of #n" in the SUBJECT as a closing claim' {
            $null = Add-FixtureCommit 'docs: explain the flow, Refs #70'
            $null = Add-FixtureCommit 'docs: explain the flow, Part of #71'
            @((Get-LinkedFor 70).commits).Count | Should -Be 0
            @((Get-LinkedFor 71).commits).Count | Should -Be 0
        }
    }

    Context 'a revert cites (#n) because the work was undone (#471)' {
        It 'a revert alone is not landed work: the restart is not refused' {
            $null = Add-FixtureCommit 'revert(work): back out the flaky change (#80)'
            $l = Get-LinkedFor 80
            @($l.commits).Count | Should -Be 0
            $l.revertedAt       | Should -Not -BeNullOrEmpty
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Be ''
        }
        It 'work that landed and was then reverted is not integrated either' {
            $null = Add-FixtureCommit 'feat(work): the change (#81) (#91)'
            $null = Add-FixtureCommit 'revert(work): undo the change (#81) (#92)'
            $l = Get-LinkedFor 81
            @($l.commits).Count | Should -Be 0
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Be ''
        }
        It 'work that landed, was reverted and then LANDED AGAIN is integrated (the newest wins)' {
            $null = Add-FixtureCommit 'feat(work): the change (#82) (#93)'
            $null = Add-FixtureCommit 'revert(work): undo the change (#82) (#94)'
            $null = Add-FixtureCommit 'feat(work): the change, second attempt (#82) (#95)'
            @((Get-LinkedFor 82).commits).Count | Should -Be 1
        }
        It 'git''s own `Revert "..."` form, naming the sha, retires exactly that commit' {
            $orig = Add-FixtureCommit 'feat(work): a change (#83) (#96)'
            $null = Add-FixtureCommit "Revert `"feat(work): a change (#83) (#96)`"`n`nThis reverts commit $orig."
            @((Get-LinkedFor 83).commits).Count | Should -Be 0
        }
        It 'a MERGED PR that a later revert undid does not count, one merged AFTER it does' {
            $revertDate = $script:Clock.AddHours(1)
            $null = Add-FixtureCommit 'revert(work): back out (#84) (#97)'
            $before = ($revertDate.AddDays(-2)).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $after  = ($revertDate.AddDays(2)).ToString('yyyy-MM-ddTHH:mm:ssZ')

            $l = Get-LinkedFor 84 ('[{"number":9,"state":"MERGED","mergedAt":"' + $before + '"}]')
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Be ''

            $l = Get-LinkedFor 84 ('[{"number":9,"state":"MERGED","mergedAt":"' + $after + '"}]')
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Match 'PR MERGED'
        }
        It 'an unreadable mergedAt can only keep the refusal, never lift it' {
            $l = Get-LinkedFor 84 '[{"number":9,"state":"MERGED"}]'
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Match 'PR MERGED'
        }
        It 'a revert that cites a DIFFERENT issue does not unlock this one' {
            $null = Add-FixtureCommit 'feat(work): kept change (#85) (#98)'
            $null = Add-FixtureCommit 'revert(work): unrelated (#86) (#99)'
            @((Get-LinkedFor 85).commits).Count | Should -Be 1
        }
    }

    Context 'the PR half of the guard is untouched' {
        It 'a MERGED PR with no revert still refuses, an OPEN PR still refuses' {
            $l = Get-LinkedFor 900 '[{"number":9,"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}]'
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Match 'PR MERGED'
            $l = Get-LinkedFor 900 '[{"number":9,"state":"OPEN"}]'
            Get-PriorWorkRefusal -Prs $l.prs -Commits $l.commits -RevertedAt $l.revertedAt | Should -Match 'PR abierto'
        }
    }
}

Describe 'Select-IssueCitingCommits when commit dates are missing (fail closed)' {
    # Hits shaped like gh's, but WITHOUT dates: ordering cannot be established, so a citing
    # non-revert commit must be kept - except a revert itself and a commit a revert names by sha.
    It 'a revert with no date is still never landed work' {
        $h = @([pscustomobject]@{ sha = 'a1a1a1a1'; commit = [pscustomobject]@{ message = 'revert(x): back out (#5)' } })
        $s = Select-IssueCitingCommits -Hits $h -IssueNum 5
        @($s.commits).Count | Should -Be 0
    }
    It 'a commit named by a "This reverts commit" line is retired even with no dates' {
        $h = @(
            [pscustomobject]@{ sha = 'abc1234def5678'; commit = [pscustomobject]@{ message = 'feat(x): change (#5) (#9)' } },
            [pscustomobject]@{ sha = 'ffff0000ffff00'; commit = [pscustomobject]@{ message = "Revert `"feat(x): change (#5) (#9)`"`n`nThis reverts commit abc1234def5678." } }
        )
        @((Select-IssueCitingCommits -Hits $h -IssueNum 5).commits).Count | Should -Be 0
    }
    It 'an older citing commit with no date survives an undated revert of something else (kept, not guessed away)' {
        $h = @(
            [pscustomobject]@{ sha = '1111111aaaa'; commit = [pscustomobject]@{ message = 'feat(x): change (#5) (#9)' } },
            [pscustomobject]@{ sha = '2222222bbbb'; commit = [pscustomobject]@{ message = 'revert(x): undo a different bit (#5) (#10)' } }
        )
        @((Select-IssueCitingCommits -Hits $h -IssueNum 5).commits).Count | Should -Be 1
    }
}

Describe 'Select-IssueCitingCommits keeps a citing commit whose own date is missing' {
    It 'a dated revert cannot retire an undated citing commit: order unknown means the refusal stays' {
        $h = @(
            [pscustomobject]@{ sha = '3333333cccc'; commit = [pscustomobject]@{ message = 'feat(x): change (#5) (#9)' } },
            [pscustomobject]@{ sha = '4444444dddd'; commit = [pscustomobject]@{ message = 'revert(x): undo (#5) (#10)'; committer = [pscustomobject]@{ date = '2026-02-01T00:00:00Z' } } }
        )
        $s = Select-IssueCitingCommits -Hits $h -IssueNum 5
        @($s.commits).Count | Should -Be 1
        $s.revertedAt       | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-IssueStart with the REAL prior-work guard (#507 #471, only the gh transport faked)' {
    BeforeEach {
        Mock Get-IssueBlockers { @() }
        Mock Get-LastClaim     { '' }
        Mock Invoke-GhRaw {
            if ($GhArgs -contains 'graphql') {
                return [pscustomobject]@{ ExitCode = 0; StdErr = ''
                    Output = '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":' + $script:PrJson + '}}}}}' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdErr = ''; Output = $script:HitsJson }
        }
        Mock Get-BoardItem {
            [pscustomobject]@{
                id = 'ITEM'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content = [pscustomobject]@{
                    __typename = 'Issue'; number = 1; title = 'Do a thing'; state = 'OPEN'; url = 'u'
                    assignees  = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'o/r' }
                }
            }
        }
        $script:Ctx2 = [pscustomobject]@{ projectId = 'P'; statusNode = [pscustomobject]@{ id = 'F' }; inProgId = 'O' }
        $script:PrJson = '[]'
    }

    It 'starts an issue whose number only appears in another commit''s body' {
        $null = Add-FixtureCommit "chore(deps): bump lib (#700)`n`nDeferred: lib 9->10 (#701) - later"
        $script:HitsJson = Get-FixtureHits
        $r = Invoke-IssueStart -IssueNum 701 -Ctx $script:Ctx2 -Owner 'me' -DryRunStart
        $r.skipped | Should -Be ''
        $r.dryRun  | Should -BeTrue
    }
    It 'still refuses when a subject cites the issue' {
        $null = Add-FixtureCommit 'fix(work): landed (#702) (#703)'
        $script:HitsJson = Get-FixtureHits
        $r = Invoke-IssueStart -IssueNum 702 -Ctx $script:Ctx2 -Owner 'me' -DryRunStart
        $r.skipped | Should -Match 'YA TRABAJADO'
    }
    It 'restarts an issue whose only landed PR was reverted (the revert date reaches the PR check)' {
        $null = Add-FixtureCommit 'revert(work): back out the PR (#704) (#705)'
        $script:HitsJson = Get-FixtureHits
        $script:PrJson   = '[{"number":9,"state":"MERGED","mergedAt":"2000-01-01T00:00:00Z"}]'
        $r = Invoke-IssueStart -IssueNum 704 -Ctx $script:Ctx2 -Owner 'me' -DryRunStart
        $r.skipped | Should -Be ''
        $r.dryRun  | Should -BeTrue
    }
}

Describe 'pending list shows the LIVE issue title (#522)' {
    It 'prefers content.title over the stale Projects item title' {
        $item = [pscustomobject]@{
            title   = 'old title captured when the item joined the board'
            content = [pscustomobject]@{ type = 'Issue'; number = 7; title = 'the renamed title' }
        }
        Get-PendingItemTitle $item | Should -Be 'the renamed title'
    }
    It 'falls back to the item title for a draft note, which has no content title' {
        $draft = [pscustomobject]@{ title = 'draft note'; content = [pscustomobject]@{ type = 'DraftIssue' } }
        Get-PendingItemTitle $draft | Should -Be 'draft note'
        Get-PendingItemTitle ([pscustomobject]@{ title = 'no content at all' }) | Should -Be 'no content at all'
    }
    It 'the pending-list render loop reads the title through Get-PendingItemTitle on both issue paths' {
        # The loop is script-level (needs a live board), so pin the wiring: neither issue line may
        # format $p.title directly again.
        $src = Get-Content -LiteralPath $script:Script -Raw
        $src | Should -Match '\[BLOCKED\] \{1\}" -f \$p\.content\.number, \(Get-PendingItemTitle \$p\)'
        $src | Should -Match '"  #\{0,-4\} \{1\}" -f \$p\.content\.number, \(Get-PendingItemTitle \$p\)'
        $src | Should -Not -Match 'content\.number, \$p\.title'
    }
}
