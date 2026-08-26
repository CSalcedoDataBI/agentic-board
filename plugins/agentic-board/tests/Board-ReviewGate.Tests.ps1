#Requires -Modules Pester
<#  Tests for Board-ReviewGate.ps1's pure foreign-commit detection (#309).

    Board-ReviewGate.ps1 is side-effecting (reads the PR over gh, waits for CI/review), so it exposes
    a dot-source guard: with $env:ABIOS_REVIEWGATE_DOTSOURCE set it returns after defining the pure
    helper. Find-ForeignCommits is the defence-in-depth backstop for #294: a commit GitHub associates
    with a DIFFERENT PR is not this issue's work. It is warn-only — these tests pin the detection, and
    the known limitation (a commit with no PR of its own is invisible) is asserted, not papered over. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-ReviewGate.ps1' | Resolve-Path
    $env:ABIOS_REVIEWGATE_DOTSOURCE = '1'
    . $script:Script -Repo 'owner/repo'    # -Repo is Mandatory; the guard returns before it is used
    $env:ABIOS_REVIEWGATE_DOTSOURCE = ''
}

Describe 'Find-ForeignCommits — warn on commits owned by another PR (#309)' {
    It 'returns nothing when every commit belongs only to this PR (no false positive)' {
        $c = @(
            [pscustomobject]@{ Sha = 'aaa'; Pulls = @(50) },
            [pscustomobject]@{ Sha = 'bbb'; Pulls = @(50) }
        )
        Find-ForeignCommits -SelfPr 50 -Commits $c | Should -BeNullOrEmpty
    }
    It 'flags a commit associated with a DIFFERENT PR' {
        $f = Find-ForeignCommits -SelfPr 50 -Commits @([pscustomobject]@{ Sha = 'ccc'; Pulls = @(99) })
        @($f).Count      | Should -Be 1
        $f[0].Sha        | Should -Be 'ccc'
        $f[0].OtherPrs   | Should -Contain 99
    }
    It 'ignores this PR in a mixed association but keeps the foreign one' {
        $f = Find-ForeignCommits -SelfPr 50 -Commits @([pscustomobject]@{ Sha = 'ddd'; Pulls = @(50, 77) })
        @($f).Count      | Should -Be 1
        $f[0].OtherPrs   | Should -Be @(77)
    }
    It 'treats a commit with no PR association as not-foreign (invisible to this signal, documented)' {
        Find-ForeignCommits -SelfPr 50 -Commits @([pscustomobject]@{ Sha = 'eee'; Pulls = @() }) |
            Should -BeNullOrEmpty
    }
    It 'handles an empty commit set' {
        Find-ForeignCommits -SelfPr 50 -Commits @() | Should -BeNullOrEmpty
    }
}


Describe 'Get-ReviewEvidence - "found nothing" vs "nobody looked" (#510)' {
    # The defect: `claude-review` reported a PASSING check having left zero reviews, and the gate
    # printed the same GATE PASSED it prints for a real clean review. Silence read as approval, in
    # the one window where it mattered - Copilot was quota-blocked, so that workflow was the ONLY
    # reviewer on the repo.
    BeforeAll {
        $script:Head = 'abc123def456abc123def456abc123def456abcd'
        $script:Old  = '999999999999999999999999999999999999aaaa'
        function script:GhReview([string]$state, [string]$who, [string]$oid) {
            [pscustomobject]@{ state = $state; author = @{ login = $who }; commit = @{ oid = $oid } }
        }
    }

    Context 'nobody reviewed' {
        It 'reports not-reviewed for no reviews and no comments' {
            $e = Get-ReviewEvidence -Reviews @() -CommentBodies @() -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.github   | Should -Be 0
            $e.external | Should -Be 0
            $e.stale    | Should -Be 0
        }
        It 'does NOT count ordinary PR chatter as a review' {
            $e = Get-ReviewEvidence -CommentBodies @('ya lo empujo','CI verde','gracias!') -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
        }
        It 'does not count a null review entry' {
            $e = Get-ReviewEvidence -Reviews @($null) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
        }
        It 'does not count a review object with no state' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReview '' 'x' $script:Head)) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
        }
    }

    Context 'a real GitHub review on THIS commit' {
        It 'counts an approval'   { (Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Head)) -HeadSha $script:Head).reviewed | Should -BeTrue }
        It 'counts a COMMENTED review that found nothing - reviewed IS reviewed' {
            (Get-ReviewEvidence -Reviews @((script:GhReview 'COMMENTED' 'copilot' $script:Head)) -HeadSha $script:Head).reviewed | Should -BeTrue
        }
        It 'counts CHANGES_REQUESTED (the blocker is decided elsewhere; this only asks "did anyone look")' {
            (Get-ReviewEvidence -Reviews @((script:GhReview 'CHANGES_REQUESTED' 'copilot' $script:Head)) -HeadSha $script:Head).reviewed | Should -BeTrue
        }
        It 'names the reviewer' {
            (Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Head)) -HeadSha $script:Head).reviewers | Should -Contain 'copilot'
        }
    }

    Context 'a review published as a comment' {
        # How the reviewers that actually show up here work: the workflow comments, and an external
        # reviewer (Codex) has no GitHub identity to submit a review object with.
        It 'counts a marked comment carrying this sha' {
            $e = Get-ReviewEvidence -CommentBodies @("<!-- [abios-review] claude-review sha=$script:Head -->`nsin hallazgos") -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.external | Should -Be 1
        }
        It 'names the external reviewer without eating its hyphen' {
            (Get-ReviewEvidence -CommentBodies @("<!-- [abios-review] codex/gpt-5.5 sha=$script:Head -->") -HeadSha $script:Head).reviewers |
                Should -Contain 'codex/gpt-5.5'
        }
        It 'adds up both kinds' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Head)) `
                                    -CommentBodies @("<!-- [abios-review] codex sha=$script:Head -->") -HeadSha $script:Head
            $e.github | Should -Be 1 ; $e.external | Should -Be 1 ; $e.reviewed | Should -BeTrue
        }
    }

    Context 'evidence must belong to THIS diff (external review, round 1)' {
        # Counting any review ever left on the PR reproduces the original defect one level up: push
        # three commits after an approval and the gate would authorise a diff nobody read.
        It 'does NOT count a GitHub review of an earlier commit' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Old)) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.stale    | Should -Be 1
        }
        It 'does NOT count an external review recorded for an earlier commit' {
            $e = Get-ReviewEvidence -CommentBodies @("<!-- [abios-review] codex sha=$script:Old -->") -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.stale    | Should -Be 1
        }
        It 'does NOT count a marker with no sha at all - it cannot be placed' {
            $e = Get-ReviewEvidence -CommentBodies @('<!-- [abios-review] codex -->') -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.stale    | Should -Be 1
        }
        It 'counts the fresh review and reports the stale one alongside it' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Old)) `
                                    -CommentBodies @("<!-- [abios-review] codex sha=$script:Head -->") -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.stale    | Should -Be 1
        }
        It 'fails CLOSED when there is no head sha to compare against' {
            # Cannot prove any evidence belongs to this diff -> accept none.
            $e = Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'copilot' $script:Head)) `
                                    -CommentBodies @("<!-- [abios-review] codex sha=$script:Head -->") -HeadSha ''
            $e.reviewed | Should -BeFalse
            $e.stale    | Should -Be 2
        }
    }

    Context 'self-certification guard (#541/#622) - opt-in via -PrAuthorLogin' {
        # The hole: the account that opened the PR posts its own [abios-review] comment (or,
        # less plausibly, its own review object) claiming an independent review that never
        # happened. Convincing text does not matter - only identity does.
        BeforeAll {
            function script:GhComment([string]$body, [string]$who) {
                [pscustomobject]@{ body = $body; author = @{ login = $who } }
            }
        }

        It 'is a no-op when -PrAuthorLogin is not passed - every pre-#622 caller is unaffected' {
            $e = Get-ReviewEvidence -CommentBodies @((script:GhComment "<!-- [abios-review] codex sha=$script:Head -->" 'the-pr-author')) -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
        }
        It 'rejects a marked comment authored by the PR''s own account' {
            $e = Get-ReviewEvidence -CommentBodies @((script:GhComment "<!-- [abios-review] codex sha=$script:Head -->" 'the-pr-author')) `
                                    -HeadSha $script:Head -PrAuthorLogin 'the-pr-author'
            $e.reviewed | Should -BeFalse
            $e.external | Should -Be 0
        }
        It 'still accepts a marked comment from a DIFFERENT account (the actual fix target)' {
            $e = Get-ReviewEvidence -CommentBodies @((script:GhComment "<!-- [abios-review] codex-rescue sha=$script:Head -->" 'github-actions[bot]')) `
                                    -HeadSha $script:Head -PrAuthorLogin 'the-pr-author'
            $e.reviewed | Should -BeTrue
        }
        It 'rejects a self-authored GitHub review object the same way' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReview 'APPROVED' 'the-pr-author' $script:Head)) `
                                    -HeadSha $script:Head -PrAuthorLogin 'the-pr-author'
            $e.reviewed | Should -BeFalse
        }
        It 'a plain string CommentBodies entry (no author to check) is unaffected by -PrAuthorLogin' {
            # Legacy shape support: callers that still pass bare strings have no identity to filter
            # on, so the marker match runs exactly as before even when -PrAuthorLogin is supplied.
            $e = Get-ReviewEvidence -CommentBodies @("<!-- [abios-review] codex sha=$script:Head -->") `
                                    -HeadSha $script:Head -PrAuthorLogin 'the-pr-author'
            $e.reviewed | Should -BeTrue
        }
        It 'one self-authored and one independent comment: only the independent one counts' {
            $e = Get-ReviewEvidence -CommentBodies @(
                (script:GhComment "<!-- [abios-review] self sha=$script:Head -->" 'the-pr-author'),
                (script:GhComment "<!-- [abios-review] codex-rescue sha=$script:Head -->" 'github-actions[bot]')
            ) -HeadSha $script:Head -PrAuthorLogin 'the-pr-author'
            $e.reviewed | Should -BeTrue
            $e.external | Should -Be 1
            $e.reviewers | Should -Contain 'codex-rescue'
            $e.reviewers | Should -Not -Contain 'self'
        }
    }

    Context 'a reviewer that answered it could NOT review (#651)' {
        # The hole #510 left open. Copilot with no quota does not stay silent - it SUBMITS a
        # COMMENTED review whose body says it was unable to review. That is a review object on the
        # current head, so the evidence count accepted it and the gate printed GATE PASSED /
        # exit 0, naming as reviewer a bot that had just said it never looked. A refusal is an
        # answer, not a review.
        BeforeAll {
            $script:Refusal = 'Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.'
            function script:GhReviewBody([string]$state, [string]$who, [string]$oid, [string]$body) {
                [pscustomobject]@{ state = $state; author = @{ login = $who }; commit = @{ oid = $oid }; body = $body }
            }
        }

        It 'does NOT count the quota refusal as a review' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head $script:Refusal)) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.github   | Should -Be 0
        }
        It 'names the refusal instead of hiding it - it is neither evidence nor stale' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head $script:Refusal)) -HeadSha $script:Head
            $e.refused | Should -Be 1
            $e.stale   | Should -Be 0
        }
        It 'does not name the refusing bot as a reviewer' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head $script:Refusal)) -HeadSha $script:Head
            $e.reviewers | Should -Not -Contain 'copilot-pull-request-reviewer'
        }
        It 'still counts a REAL Copilot review that has findings' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head 'Two nits: the null check on line 12, and the unused import.')) -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.github   | Should -Be 1
            $e.refused  | Should -Be 0
        }
        It 'does NOT reach into a human review that merely uses the words in prose' {
            # Scoped to the bot on purpose: 'that API is not available in this version' is ordinary
            # review prose, and dropping a human review over a phrase match would be a worse bug
            # than the one being fixed.
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'a-human' $script:Head 'That API is not available in this version - use the other one.')) -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.github   | Should -Be 1
        }
        It 'a refusal alongside a real external review leaves the external one counting' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head $script:Refusal)) `
                                    -CommentBodies @("<!-- [abios-review] codex sha=$script:Head -->") -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.github   | Should -Be 0
            $e.external | Should -Be 1
            $e.refused  | Should -Be 1
        }
        It 'a refusal left on an EARLIER commit is stale, not a refusal of this diff' {
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Old $script:Refusal)) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.refused  | Should -Be 0
            $e.stale    | Should -Be 1
        }
        It 'a refusal now AND a real review of an earlier commit: one of each, counted separately' {
            # Both verdict branches are live at once; each keeps its own count, so the message the
            # gate picks is a choice between two true statements, not a collision.
            $e = Get-ReviewEvidence -Reviews @(
                (script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head $script:Refusal),
                (script:GhReviewBody 'APPROVED'  'a-human'                       $script:Old  'Looks good.')
            ) -HeadSha $script:Head
            $e.reviewed | Should -BeFalse
            $e.refused  | Should -Be 1
            $e.stale    | Should -Be 1
        }
        It 'keeps a SUBSTANTIVE Copilot review that happens to say something is not available (#651, review round 1)' {
            # The escalation this fix created: the refusal phrase list used to be loose enough to
            # match ordinary review prose. Harmless while it only skipped a re-request; once it
            # removes evidence, a real review would be thrown away and the PR called unreviewed.
            $e = Get-ReviewEvidence -Reviews @((script:GhReviewBody 'COMMENTED' 'copilot-pull-request-reviewer' $script:Head 'Line 42: that helper is not available in v2 of the API - use the new one.')) -HeadSha $script:Head
            $e.reviewed | Should -BeTrue
            $e.github   | Should -Be 1
            $e.refused  | Should -Be 0
        }
    }
}

Describe 'Test-OnlyReviewerChecksFailed - the reviewer-red allowance (#510, review round 4)' {
    # This gates a MERGE decision, so its failure mode matters more than its happy path. The first
    # cut scraped the human-readable `gh pr checks` table; any failure printed in a shape the regex
    # missed dropped out of the list, a reviewer failure was then the only one seen, and a broken
    # build would have been waved through.

    Context 'fails closed' {
        It 'never downgrades when the check list could not be parsed' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('claude-review') -Parsed $false | Should -BeFalse
        }
        It 'never downgrades on an empty failure list (nothing to excuse)' {
            Test-OnlyReviewerChecksFailed -FailedChecks @() -Parsed $true | Should -BeFalse
        }
        It 'never downgrades when a list of blanks is all there is' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('', '   ') -Parsed $true | Should -BeFalse
        }
        It 'never downgrades while checks are still PENDING - excusing the reviewer there would excuse the CI timeout (#562)' {
            # External-review finding: reviewer red + another check pending at the CI deadline.
            # "The only FAILURE is the reviewer" says nothing about the pending ones.
            Test-OnlyReviewerChecksFailed -FailedChecks @('claude-review') -Parsed $true -Settled $false | Should -BeFalse
        }
    }

    Context 'a real build failure always blocks' {
        It 'blocks when tests failed alongside the reviewer' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('claude-review','Pester') -Parsed $true | Should -BeFalse
        }
        It 'blocks when only a build failed' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('Pester') -Parsed $true | Should -BeFalse
        }
        It 'blocks on a check whose name merely mentions review-adjacent words' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('security-audit') -Parsed $true | Should -BeFalse
        }
    }

    Context 'the reviewer alone' {
        It 'allows the bare job name' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('claude-review') -Parsed $true | Should -BeTrue
        }
        It 'allows the namespaced check-run name GitHub actually reports' {
            # `gh pr checks` reports the display name, which repos namespace as "<workflow> / <job>".
            Test-OnlyReviewerChecksFailed -FailedChecks @('PR Review (@claude) / claude-review') -Parsed $true | Should -BeTrue
        }
        It 'allows a Copilot-flavoured reviewer name' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('Copilot review') -Parsed $true | Should -BeTrue
        }
        It 'allows several reviewer jobs together' {
            Test-OnlyReviewerChecksFailed -FailedChecks @('claude-review','copilot-review') -Parsed $true | Should -BeTrue
        }
    }

    Context 'Test-IsReviewerCheck' {
        It 'recognises claude-review'            { Test-IsReviewerCheck 'claude-review'  | Should -BeTrue }
        It 'recognises pr-review'                { Test-IsReviewerCheck 'pr-review'      | Should -BeTrue }
        It 'does not recognise an empty name'    { Test-IsReviewerCheck ''               | Should -BeFalse }
        It 'does not recognise a build job'      { Test-IsReviewerCheck 'Pester'         | Should -BeFalse }
        It 'does not recognise "Docs freshness"' { Test-IsReviewerCheck 'Docs freshness' | Should -BeFalse }
    }
}

Describe 'Get-ChecksVerdict - one snapshot, fail-closed (#562)' {
    # Replaces trusting `gh pr checks --watch` (unbounded, exit-code driven). The verdict is
    # computed from one structured snapshot; whatever cannot be read can only ever block.
    BeforeAll {
        function script:Chk([string]$name, [string]$bucket) {
            [pscustomobject]@{ name = $name; bucket = $bucket }
        }
    }

    Context 'fails closed' {
        It 'an unparsed snapshot is neither settled nor ok' {
            $v = Get-ChecksVerdict -Checks @() -Parsed $false
            $v.Settled | Should -BeFalse
            $v.Ok      | Should -BeFalse
            $v.Parsed  | Should -BeFalse
        }
        It 'an unparsed snapshot never reports NoChecks (cannot know that)' {
            (Get-ChecksVerdict -Checks @() -Parsed $false).NoChecks | Should -BeFalse
        }
    }

    Context 'no checks configured' {
        It 'an empty PARSED list is the benign case: settled, ok, flagged NoChecks' {
            $v = Get-ChecksVerdict -Checks @() -Parsed $true
            $v.Settled  | Should -BeTrue
            $v.Ok       | Should -BeTrue
            $v.NoChecks | Should -BeTrue
        }
    }

    Context 'buckets' {
        It 'all pass -> settled and ok' {
            $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'pass'), (script:Chk 'lint' 'pass')) -Parsed $true
            $v.Settled | Should -BeTrue ; $v.Ok | Should -BeTrue
            @($v.Failed).Count | Should -Be 0
        }
        It 'a pending check means NOT settled, and is named' {
            $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'pass'), (script:Chk 'build' 'pending')) -Parsed $true
            $v.Settled | Should -BeFalse
            $v.Pending | Should -Contain 'build'
        }
        It 'a fail is settled but not ok, and is named' {
            $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'fail')) -Parsed $true
            $v.Settled | Should -BeTrue ; $v.Ok | Should -BeFalse
            $v.Failed  | Should -Contain 'Pester'
        }
        It 'cancel counts as failed - a cancelled check did not pass' {
            (Get-ChecksVerdict -Checks @((script:Chk 'build' 'cancel')) -Parsed $true).Failed | Should -Contain 'build'
        }
        It 'skipping counts as settled-ok (mirrors the previous verdict)' {
            $v = Get-ChecksVerdict -Checks @((script:Chk 'docs' 'skipping')) -Parsed $true
            $v.Settled | Should -BeTrue ; $v.Ok | Should -BeTrue
        }
    }
}

Describe 'Test-GateWaitDone - CI and review waited concurrently (#562)' {
    # The property under test: total wait is max(CI, review), never their sum, and BOTH sides
    # have a deadline - the unbounded CI watch is gone.
    BeforeAll {
        $script:T0     = [datetime]'2026-08-03T10:00:00'
        $script:Later  = $script:T0.AddMinutes(60)
    }

    It 'keeps waiting while checks are pending and CI deadline has not passed' {
        Test-GateWaitDone -ChecksSettled $false -WaitingReview $false `
            -Now $script:T0 -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeFalse
    }
    It 'keeps waiting for the review even when CI already settled (concurrent, not sequential)' {
        Test-GateWaitDone -ChecksSettled $true -WaitingReview $true `
            -Now $script:T0 -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeFalse
    }
    It 'exits when both sides are done' {
        Test-GateWaitDone -ChecksSettled $true -WaitingReview $false `
            -Now $script:T0 -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeTrue
    }
    It 'the CI deadline bounds the wait - pending checks stop blocking the exit once it passes' {
        Test-GateWaitDone -ChecksSettled $false -WaitingReview $false `
            -Now $script:Later -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeTrue
    }
    It 'the review deadline bounds the wait - a silent reviewer stops blocking the exit once it passes' {
        Test-GateWaitDone -ChecksSettled $true -WaitingReview $true `
            -Now $script:Later -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeTrue
    }
    It 'waits for the LATER of the two sides, not their sum (max, not plus)' {
        # 10 min in: CI (25m) still pending, review deadline (6m) already passed.
        # The only thing keeping the loop alive is CI - the review side is done.
        $now = $script:T0.AddMinutes(10)
        Test-GateWaitDone -ChecksSettled $false -WaitingReview $true `
            -Now $now -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeFalse   # still waiting, but ONLY on CI
        Test-GateWaitDone -ChecksSettled $true -WaitingReview $true `
            -Now $now -CiDeadline $script:T0.AddMinutes(25) -ReviewDeadline $script:T0.AddMinutes(6) |
            Should -BeTrue    # CI settles -> nothing else to wait for
    }
}

Describe 'Wait-loop arrival reuses Get-ReviewEvidence - ANY answer for the current head ends the wait (#563)' {
    # The loop calls Get-ReviewEvidence (already pinned exhaustively above) for arrival. These
    # tests pin the PROPERTY that matters to the wait: humans, Copilot and recorded external
    # reviews all count as arrival; stale evidence of earlier commits does not.
    BeforeAll {
        $script:Head = 'abc123def456abc123def456abc123def456abcd'
        $script:Old  = '999999999999999999999999999999999999aaaa'
        function script:Rev([string]$who, [string]$oid) {
            [pscustomobject]@{ state = 'COMMENTED'; author = @{ login = $who }; commit = @{ oid = $oid } }
        }
    }

    It 'a HUMAN review of the current head is an arrival - not only Copilot''s' {
        (Get-ReviewEvidence -Reviews @((script:Rev 'cristobal' $script:Head)) -HeadSha $script:Head).reviewed | Should -BeTrue
    }
    It 'a recorded EXTERNAL review ([abios-review] comment) is an arrival - the gate''s own channel counts' {
        (Get-ReviewEvidence -CommentBodies @("<!-- [abios-review] codex/gpt-5.5 sha=$script:Head -->") -HeadSha $script:Head).reviewed | Should -BeTrue
    }
    It 'a STALE review (earlier commit) is NOT an arrival - it is evidence the verdict will refuse' {
        (Get-ReviewEvidence -Reviews @((script:Rev 'copilot' $script:Old)) -HeadSha $script:Head).reviewed | Should -BeFalse
    }
}

Describe 'Test-ReviewAnswerArrived - a refusal ends the WAIT without passing the GATE (#651)' {
    # Two questions that used to share one answer. Once a refusal stopped counting as a review,
    # reusing `.reviewed` for arrival would have made a ten-second "no quota" answer cost the full
    # review timeout - a guaranteed stall traded for the false pass. The wait asks "did the
    # reviewer respond"; the verdict asks "did anyone review".
    It 'a real review is an arrival' {
        Test-ReviewAnswerArrived -Evidence @{ reviewed = $true; refused = 0 } | Should -BeTrue
    }
    It 'a REFUSAL is an arrival too - waiting longer cannot produce a review that is not coming' {
        Test-ReviewAnswerArrived -Evidence @{ reviewed = $false; refused = 1 } | Should -BeTrue
    }
    It 'nothing at all is not an arrival - the wait continues' {
        Test-ReviewAnswerArrived -Evidence @{ reviewed = $false; refused = 0 } | Should -BeFalse
    }
    It 'fails closed (keeps waiting) on a null evidence object' {
        Test-ReviewAnswerArrived -Evidence $null | Should -BeFalse
    }
    It 'tolerates evidence with no refused key at all (a pre-#651 shape)' {
        Test-ReviewAnswerArrived -Evidence @{ reviewed = $false } | Should -BeFalse
    }
}

Describe 'Test-CopilotSilentTimeout - silence past the deadline is evidence too (#563)' {
    # The defect: the cooldown only armed on an explicit "cannot review" answer. A silent Copilot
    # taught the gate nothing, so EVERY PR paid the full review timeout, forever.
    BeforeAll {
        $script:T0 = [datetime]'2026-08-03T10:00:00'
        $script:Deadline = $script:T0.AddMinutes(6)
    }

    It 'arms when requested + silent + deadline passed' {
        Test-CopilotSilentTimeout -Requested $true -Answered $false -Now $script:Deadline.AddSeconds(1) -Deadline $script:Deadline | Should -BeTrue
    }
    It 'does NOT arm before the deadline - a slow reviewer is not an absent one yet' {
        Test-CopilotSilentTimeout -Requested $true -Answered $false -Now $script:T0.AddMinutes(3) -Deadline $script:Deadline | Should -BeFalse
    }
    It 'does NOT arm when Copilot answered (the explicit-refusal path owns that case)' {
        Test-CopilotSilentTimeout -Requested $true -Answered $true -Now $script:Deadline.AddMinutes(1) -Deadline $script:Deadline | Should -BeFalse
    }
    It 'does NOT arm when Copilot was never requested - a skipped run has nothing new to learn' {
        Test-CopilotSilentTimeout -Requested $false -Answered $false -Now $script:Deadline.AddMinutes(1) -Deadline $script:Deadline | Should -BeFalse
    }
}

Describe 'Get-CodexRescueMarker - parses a codex-rescue marker out of a comment body (#644)' {
    It 'extracts rollout path and thread id from a well-formed marker' {
        $m = Get-CodexRescueMarker -Body '<!-- [abios-review] codex-rescue sha=abc rollout="C:\Users\me\.codex\sessions\r.jsonl" thread=01a02004 -->'
        $m.Found       | Should -BeTrue
        $m.RolloutPath | Should -Be 'C:\Users\me\.codex\sessions\r.jsonl'
        $m.ThreadId    | Should -Be '01a02004'
    }
    It 'tolerates a thread id glued to the closing comment marker (no space before -->)' {
        $m = Get-CodexRescueMarker -Body '<!-- [abios-review] codex-rescue sha=abc rollout="C:\r.jsonl" thread=01a02004-->'
        $m.ThreadId | Should -Be '01a02004'
    }
    It 'reports not-found on a plain -RecordReview comment with no codex fields' {
        $m = Get-CodexRescueMarker -Body '<!-- [abios-review] cristobal sha=abc -->'
        $m.Found | Should -BeFalse
    }
    It 'reports not-found when only one of the two fields is present (malformed, not partial)' {
        (Get-CodexRescueMarker -Body '<!-- [abios-review] x sha=abc rollout="C:\r.jsonl" -->').Found | Should -BeFalse
        (Get-CodexRescueMarker -Body '<!-- [abios-review] x sha=abc thread=01a02004 -->').Found      | Should -BeFalse
    }
    # Review round 1, Copilot on #645: parsing used to scan the WHOLE comment body, so a genuine
    # human -RecordReview whose free-text Summary happened to mention "thread=" / "rollout=" as
    # ordinary prose (not a codex-rescue claim at all) would be misread as a marker and then
    # dropped as unverifiable under -PreferCodexRescue - a real review punished for its wording.
    It 'ignores rollout=/thread= tokens with NO [abios-review] marker at all (ordinary PR comment)' {
        (Get-CodexRescueMarker -Body 'I checked the thread=3 issue, rollout="stable" per QA notes.').Found | Should -BeFalse
    }
    It 'ignores rollout=/thread= tokens that appear in the free-text SUMMARY, outside the marker comment' {
        $body = @"
<!-- [abios-review] cristobal sha=abc -->
## Revision externa - cristobal

Reviewed the rollout="canary" plan; thread=3 on the forum has more context.
"@
        (Get-CodexRescueMarker -Body $body).Found | Should -BeFalse
    }
}

Describe 'Test-CodexRescueMarkerOnDisk - the claim must survive contact with the filesystem (#644)' {
    BeforeAll {
        $script:RealFile = Join-Path $TestDrive 'rollout-2026-08-20T11-32-48-01a02004-888b-7b21-86f8-3fe618370b11.jsonl'
        Set-Content -LiteralPath $script:RealFile -Value '{}'
    }
    It 'passes when the file exists and its name contains the claimed thread id' {
        Test-CodexRescueMarkerOnDisk -RolloutPath $script:RealFile -ThreadId '01a02004-888b-7b21-86f8-3fe618370b11' | Should -BeTrue
    }
    It 'fails when the file does not exist (a fabricated path)' {
        $missing = Join-Path $TestDrive 'rollout-does-not-exist-01a02004.jsonl'
        Test-CodexRescueMarkerOnDisk -RolloutPath $missing -ThreadId '01a02004' | Should -BeFalse
    }
    It 'fails when the file exists but the thread id does not match the filename (a real file, wrong session)' {
        Test-CodexRescueMarkerOnDisk -RolloutPath $script:RealFile -ThreadId 'totally-different-thread' | Should -BeFalse
    }
    It 'fails closed on an empty path or thread id' {
        Test-CodexRescueMarkerOnDisk -RolloutPath '' -ThreadId 'x' | Should -BeFalse
        Test-CodexRescueMarkerOnDisk -RolloutPath $script:RealFile -ThreadId '' | Should -BeFalse
    }
    # Review round 1, Copilot on #645: matching was an unanchored substring, so a SHORT PREFIX of
    # the real thread id verified too - the exact "partial/ambiguous id" hole flagged in review.
    It 'fails on a bare PREFIX of the real thread id - anchored to the filename SEGMENT, not a substring' {
        Test-CodexRescueMarkerOnDisk -RolloutPath $script:RealFile -ThreadId '01a0' | Should -BeFalse
    }
    It 'fails on a thread id that only matches inside the TIMESTAMP portion of the filename' {
        # $script:RealFile is rollout-2026-08-20T11-32-48-01a02004-....jsonl - "20" is a real
        # substring (the day), but it is not the thread-id segment the marker claims it is.
        Test-CodexRescueMarkerOnDisk -RolloutPath $script:RealFile -ThreadId '20' | Should -BeFalse
    }
}

Describe 'Get-CodexVerifiedComments - a bogus codex marker is treated as if never posted, under -PreferCodexRescue (#644)' {
    BeforeAll {
        $script:RealFile = Join-Path $TestDrive 'rollout-real-01a02004.jsonl'
        Set-Content -LiteralPath $script:RealFile -Value '{}'
        $script:GoodMarker = "<!-- [abios-review] codex-rescue sha=abc rollout=`"$script:RealFile`" thread=01a02004 -->"
        $script:BadMarker  = '<!-- [abios-review] codex-rescue sha=abc rollout="C:\does\not\exist.jsonl" thread=01a02004 -->'
        $script:PlainReview = '<!-- [abios-review] cristobal sha=abc -->'
    }

    It 'passes every comment through unchanged when -PreferCodexRescue is off (default gate behavior unchanged)' {
        $out = Get-CodexVerifiedComments -CommentBodies @($script:BadMarker, $script:PlainReview) -PreferCodexRescue $false
        @($out).Count | Should -Be 2
    }
    It 'keeps a marker that verifies on disk' {
        $out = Get-CodexVerifiedComments -CommentBodies @($script:GoodMarker) -PreferCodexRescue $true
        @($out).Count | Should -Be 1
    }
    It 'drops a marker whose rollout file does not exist - rejected, not silently accepted' {
        $out = Get-CodexVerifiedComments -CommentBodies @($script:BadMarker) -PreferCodexRescue $true
        @($out).Count | Should -Be 0
    }
    It 'never touches a comment with no codex marker at all (the human -RecordReview fallback is unaffected)' {
        $out = Get-CodexVerifiedComments -CommentBodies @($script:PlainReview) -PreferCodexRescue $true
        @($out).Count | Should -Be 1
    }
    It 'a bogus marker does not poison OTHER evidence - the good one still counts' {
        $out = @(Get-CodexVerifiedComments -CommentBodies @($script:BadMarker, $script:PlainReview) -PreferCodexRescue $true)
        $out.Count  | Should -Be 1
        $out[0]     | Should -Be $script:PlainReview
    }
    It 'end to end: a bogus marker as the ONLY evidence means Get-ReviewEvidence reports not-reviewed' {
        $head = 'abc'
        $filtered = Get-CodexVerifiedComments -CommentBodies @("<!-- [abios-review] codex-rescue sha=$head rollout=`"C:\nope.jsonl`" thread=01a02004 -->") -PreferCodexRescue $true
        (Get-ReviewEvidence -CommentBodies $filtered -HeadSha $head).reviewed | Should -BeFalse
    }
    It 'end to end: a verified marker as the ONLY evidence means Get-ReviewEvidence reports reviewed' {
        $head = 'abc'
        $marker = "<!-- [abios-review] codex-rescue sha=$head rollout=`"$script:RealFile`" thread=01a02004 -->"
        $filtered = Get-CodexVerifiedComments -CommentBodies @($marker) -PreferCodexRescue $true
        (Get-ReviewEvidence -CommentBodies $filtered -HeadSha $head).reviewed | Should -BeTrue
    }
}
