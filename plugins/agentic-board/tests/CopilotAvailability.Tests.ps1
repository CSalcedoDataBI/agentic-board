#Requires -Modules Pester
<#  Tests for CopilotAvailability.ps1 — the per-account "Copilot has no quota, stop waiting" memory (#367).

    Pure at load (functions only), so it dot-sources directly. The two decisions the gate depends on:
    (1) recognising Copilot's "unable to review / no quota" answer, and (2) deciding whether to SKIP
    Copilot given a marker entry + the current time (skip while the cooldown holds; retry once it
    expires). The marker file I/O is exercised against $TestDrive via HOME redirection. #>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'CopilotAvailability.ps1')
    function script:Review($login, $body) { [pscustomobject]@{ author = [pscustomobject]@{ login = $login }; body = $body } }
}

Describe 'Test-CopilotUnavailableReview (recognise the no-quota answer)' {
    It 'is true for the Copilot bot answering "reached their quota limit"' {
        Test-CopilotUnavailableReview @( (Review 'copilot-pull-request-reviewer' 'Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.') ) | Should -BeTrue
    }
    It 'is true for "unable to review"' {
        Test-CopilotUnavailableReview @( (Review 'Copilot' 'unable to review right now') ) | Should -BeTrue
    }
    It 'is FALSE for a real Copilot review with actual feedback' {
        Test-CopilotUnavailableReview @( (Review 'copilot-pull-request-reviewer' 'Looks good; consider renaming this variable.') ) | Should -BeFalse
    }
    It 'ignores a non-Copilot author even if the body mentions quota' {
        Test-CopilotUnavailableReview @( (Review 'alice' 'we reached their quota limit last week') ) | Should -BeFalse
    }
    It 'is false on no reviews' { Test-CopilotUnavailableReview @() | Should -BeFalse }

    Context 'the phrase has to be about REVIEWING, not any availability word (#651)' {
        # This verdict used to only decide whether to re-request Copilot next time - a false
        # positive cost one skipped request. Since #651 it REMOVES the review from the gate's
        # evidence, so a false positive now reports a reviewed PR as unreviewed. Ordinary review
        # prose must not trip it.
        It 'is FALSE for a substantive Copilot review that says an API is not available' {
            Test-CopilotUnavailableReview @( (Review 'copilot-pull-request-reviewer' 'Line 42: that helper is not available in v2 of the API - use the new one. Otherwise this looks correct.') ) | Should -BeFalse
        }
        It 'is FALSE for a substantive review mentioning seats in passing' {
            Test-CopilotUnavailableReview @( (Review 'copilot-pull-request-reviewer' 'The seat allocation loop drops the last row when no seats remain; add a guard.') ) | Should -BeFalse
        }
        It 'is FALSE for review prose that merely uses the word unavailable' {
            Test-CopilotUnavailableReview @( (Review 'Copilot' 'If the endpoint is unavailable this retries forever - bound it.') ) | Should -BeFalse
        }
        It 'still recognises Copilot announcing ITSELF unavailable' {
            Test-CopilotUnavailableReview @( (Review 'Copilot' 'Copilot code review is not available for this repository.') ) | Should -BeTrue
        }
        It 'still recognises the out-of-quota phrasings' {
            Test-CopilotUnavailableReview @( (Review 'Copilot' 'This account is out of quota for code review.') ) | Should -BeTrue
            Test-CopilotUnavailableReview @( (Review 'Copilot' 'Copilot could not review this pull request.') ) | Should -BeTrue
        }
    }

    Context 'length is what separates a notice from a review (#651, review round 2)' {
        # The words are the same in both. A repo whose subject matter IS Copilot quota - this one -
        # will have real reviews that say "reached their quota". Only the shape of the message
        # tells them apart: GitHub's refusal is one machine sentence, a review is not.
        It 'the real refusal is recognised at any length (tier 1 phrase)' {
            Test-CopilotRefusalBody -Body 'Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.' | Should -BeTrue
        }
        It 'a SHORT exhaustion notice is a refusal' {
            Test-CopilotRefusalBody -Body 'unable to review right now' | Should -BeTrue
            Test-CopilotRefusalBody -Body 'No seats available for code review on this account.' | Should -BeTrue
        }
        It 'a LONG review that merely discusses quotas is NOT a refusal' {
            $body = 'Line 88: this correctly returns 429 when the user has reached their quota, but the retry path below does not honour the Retry-After header, so a client will hammer the endpoint. Line 140: the branch that runs when no seats are available duplicates the block above it - worth extracting. Line 210: the quota limit constant is defined twice, in this file and in the caller, and they have already drifted apart by one. Everything else reads fine to me.'
            $body.Length | Should -BeGreaterThan 400   # the guard only means something above the threshold
            Test-CopilotRefusalBody -Body $body | Should -BeFalse
        }
        It 'a long review with NO exhaustion phrase at all is not a refusal either' {
            Test-CopilotRefusalBody -Body ('Looks correct. ' * 60) | Should -BeFalse
        }
        It 'an empty body is not a refusal' {
            Test-CopilotRefusalBody -Body ''    | Should -BeFalse
            Test-CopilotRefusalBody -Body '   ' | Should -BeFalse
        }
        It 'reaches Test-CopilotUnavailableReview through the same rule' {
            $long = 'The user has reached their quota is the message this branch prints; the test below asserts it, but the assertion compares against a different constant than the one the code reads, so it passes for the wrong reason. Also the loop on line 40 recomputes the pattern on every iteration - hoist it, since it is rebuilt for each review in a list that can hold twenty of them. Nothing else stood out; the rest of the diff is mechanical and reads fine to me overall.'
            $long.Length | Should -BeGreaterThan 400
            Test-CopilotUnavailableReview @( (Review 'copilot-pull-request-reviewer' $long) ) | Should -BeFalse
        }
    }

    Context 'head-bound refusals (#563)' {
        BeforeAll {
            function script:ShaReview($login, $body, $oid) {
                [pscustomobject]@{ author = [pscustomobject]@{ login = $login }; body = $body; commit = [pscustomobject]@{ oid = $oid } }
            }
            $script:Head = 'abc123def456abc123def456abc123def456abcd'
            $script:Old  = '999999999999999999999999999999999999aaaa'
        }
        It 'with -HeadSha, a STALE refusal (earlier commit) does not count - it is not an answer to this request' {
            Test-CopilotUnavailableReview -Reviews @( (ShaReview 'Copilot' 'unable to review right now' $script:Old) ) -HeadSha $script:Head | Should -BeFalse
        }
        It 'with -HeadSha, a refusal bound to the current head DOES count' {
            Test-CopilotUnavailableReview -Reviews @( (ShaReview 'Copilot' 'unable to review right now' $script:Head) ) -HeadSha $script:Head | Should -BeTrue
        }
        It 'without -HeadSha the old any-refusal behavior holds (backward compatible)' {
            Test-CopilotUnavailableReview -Reviews @( (ShaReview 'Copilot' 'unable to review right now' $script:Old) ) | Should -BeTrue
        }
    }
}

Describe 'Get-CopilotSkipDecision (skip while the cooldown holds)' {
    BeforeAll { $script:Now = [datetime]::Parse('2026-07-20T12:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    It 'does NOT skip when there is no marker' {
        (Get-CopilotSkipDecision -Entry $null -Now $script:Now).Skip | Should -BeFalse
    }
    It 'skips while the cooldown is in the future' {
        $e = [pscustomobject]@{ state = 'unavailable'; until = '2026-07-27T12:00:00Z'; reason = 'quota' }
        (Get-CopilotSkipDecision -Entry $e -Now $script:Now).Skip | Should -BeTrue
    }
    It 'does NOT skip once the cooldown has expired (retry)' {
        $e = [pscustomobject]@{ state = 'unavailable'; until = '2026-07-19T12:00:00Z'; reason = 'quota' }
        (Get-CopilotSkipDecision -Entry $e -Now $script:Now).Skip | Should -BeFalse
    }
    It 'skips indefinitely when until is null' {
        $e = [pscustomobject]@{ state = 'unavailable'; until = $null; reason = 'manual' }
        (Get-CopilotSkipDecision -Entry $e -Now $script:Now).Skip | Should -BeTrue
    }
    It 'does NOT skip when state is not unavailable' {
        $e = [pscustomobject]@{ state = 'available'; until = '2026-07-27T12:00:00Z' }
        (Get-CopilotSkipDecision -Entry $e -Now $script:Now).Skip | Should -BeFalse
    }
}

Describe 'Marker I/O round-trip (set -> skip -> clear), keyed by owner' {
    BeforeEach {
        $script:OldHome = $HOME
        Set-Variable -Name HOME -Value "$TestDrive" -Scope Global -Force
        # SAFETY: never let these tests write to the real $HOME. If the override did not take, fail loud.
        (Get-CopilotStatePath) | Should -BeLike "$TestDrive*"
    }
    AfterEach {
        Set-Variable -Name HOME -Value $script:OldHome -Scope Global -Force
    }
    It 'Set makes the owner skip; Clear makes it try again; another owner is unaffected' {
        $now = [datetime]::Parse('2026-07-20T12:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Set-CopilotUnavailable -Owner 'CSalcedoDataBI' -Until $now.AddDays(7) -Now $now | Should -BeTrue
        (Test-CopilotShouldSkip -Owner 'CSalcedoDataBI' -Now $now).Skip | Should -BeTrue
        (Test-CopilotShouldSkip -Owner 'PAL-Devs' -Now $now).Skip       | Should -BeFalse   # per-owner
        Clear-CopilotUnavailable -Owner 'CSalcedoDataBI' | Should -BeTrue
        (Test-CopilotShouldSkip -Owner 'CSalcedoDataBI' -Now $now).Skip | Should -BeFalse
    }
    It 'a missing marker file means "do not skip" (no memory yet)' {
        (Test-CopilotShouldSkip -Owner 'CSalcedoDataBI' -Now (Get-Date)).Skip | Should -BeFalse
    }
}
