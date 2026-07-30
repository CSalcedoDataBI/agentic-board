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
