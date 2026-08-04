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
