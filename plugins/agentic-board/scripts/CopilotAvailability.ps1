<#  CopilotAvailability.ps1 — remember, per GitHub account, that Copilot code review is unavailable so
    the review gate stops requesting + WAITING for it on every PR (#367).

    The gate used to request a Copilot review and wait up to -TimeoutMinutes for it on EVERY PR, even
    on an account with no Copilot (which just answers "unable to review ... reached their quota limit").
    Quota/activation is often many days out, so re-requesting every PR — every session — is pure
    friction. This records the unavailability in a $HOME-level marker keyed by owner: once seen, the
    gate SKIPS the request + the wait and routes straight to the mandatory self-review, until a cooldown
    expires (self-healing: the gate retries once after that) or it is re-enabled.

    Global on purpose: "this account has no Copilot" is an account fact, not a repo fact, so the marker
    lives under $HOME and applies to every repo of that owner.

    Pure at load: dot-source it, it defines functions only (no I/O until called).
      . (Join-Path $PSScriptRoot 'CopilotAvailability.ps1')

    Marker shape ($HOME/.agentic-board/copilot-availability.json), a map keyed by owner:
      { "CSalcedoDataBI": { "state":"unavailable", "until":"2026-07-27T15:00:00Z",
                            "reason":"...", "detectedAt":"2026-07-20T15:00:00Z" } }
#>

# ── Pure decision helpers (unit-testable; no I/O) ─────────────────────────────

<#  What a REFUSAL sounds like, in two tiers (#651).

    This used to be one loose phrase list matched anywhere in the body - 'not available', 'no seats',
    'quota limit'. Harmless while the verdict only decided whether to re-request Copilot next time: a
    false positive cost one skipped request. Since #651 the same verdict REMOVES the review from the
    gate's evidence, so a false positive now reports a genuinely reviewed PR as unreviewed. The blast
    radius grew from bookkeeping to blocking a merge.

    Tightening the phrases was not enough on its own, and this repo is the proof: its own subject
    matter is Copilot quota, so a REAL review of this very file could easily say "returns 429 when
    the user has reached their quota" or "handle the case where no seats are available" and be
    thrown away. Phrase precision cannot separate those from the refusal, because the words are the
    same. Length can: GitHub's refusal is one machine-generated sentence; a review with something to
    say is not.

      Tier 1 - the machine sentences themselves. Unambiguous at any length.
      Tier 2 - an exhaustion phrase, but only in a body short enough to BE a notice rather than a
               review. A long review that discusses quotas keeps counting.

    Both directions still fail toward SHUT (exit 2, which -RecordReview or -AllowUnreviewed clears)
    rather than toward a merge nobody reviewed.
#>
# Tier 1 is ANCHORED to the start of the body (review round 3). Unanchored, a substantive review of
# THIS file that quotes the sentence - "the string 'unable to review this pull request' is correct" -
# matched tier 1, and tier 1 ignores length, so the whole review was thrown away. GitHub's notice
# leads with it; a review that mentions it does not.
$script:CopilotRefusalPattern    = '(?i)^\s*(?:copilot\s+)?(?:(?:was|is|were)\s+)?(?:unable|not able)\s+to\s+review|^\s*(?:copilot\s+)?(?:can''t|cannot|could\s*not|couldn''t)\s+review|^\s*copilot(?:\s+code\s+review)?\s+is\s+(?:not\s+available|unavailable)'
# Tier 2 is now EXHAUSTION ONLY - a resource actually running out (review round 4). It used to also
# carry the inability phrases ('cannot review', "can't review", 'could not review'), which are
# ordinary things for a reviewer to say about the CODE: "I can't review binary files here", "this
# helper cannot review nested objects". Under the 400-char guard a short review saying either was
# discarded as a refusal. Those phrases moved into the ANCHORED tier above, where they only count
# when the message OPENS with them - which is what a notice does and a review does not.
$script:CopilotExhaustionPattern = '(?i)(quota limit|reached (their|the|its) quota|out of quota|no seats? (available|remaining))'
$script:CopilotRefusalMaxLength  = 400

# WHO the bot is. `-match 'copilot'` was a substring test, so a HUMAN called `acme-copilot` or
# `copilot-fan` was treated as the bot (review round 3) - and since #651 that means their short
# review can be discarded as a refusal. Anchored to the logins GitHub actually uses.
$script:CopilotReviewerLoginPattern = '(?i)^copilot(-pull-request-reviewer)?(\[bot\])?$'

# Is THIS body a refusal? Pure; the two-tier rule above lives here so both consumers share it.
function Test-CopilotRefusalBody {
    param([string]$Body = '')
    $b = "$Body"
    if (-not $b.Trim()) { return $false }
    if ($b -match $script:CopilotRefusalPattern) { return $true }
    return (($b.Length -le $script:CopilotRefusalMaxLength) -and ($b -match $script:CopilotExhaustionPattern))
}

# Does a reviews list show Copilot answering that it could NOT review (no quota / unavailable)? The bot
# posts this as a COMMENTED review by copilot-pull-request-reviewer. With -HeadSha, only a refusal
# bound to THAT commit counts (#563): a stale refusal from an earlier commit is not an answer to the
# current request, and letting it renew the full cooldown suppressed the 1-day silence path the gate
# uses for a request that got no answer at all. Without -HeadSha the old any-refusal behavior holds. Pure.
# Did Copilot ONLY refuse? The cooldown must not be armed off the presence of a refusal alone.
# Test-CopilotUnavailableReview answers "is there a refusal in this array", which is the right
# question for subtracting a non-review from the evidence, and the WRONG one for arming a
# multi-day cooldown: a re-requested Copilot can answer twice on the same head, once with a real
# review and once with a refusal. Asked about the whole array, the old call saw the refusal and
# silenced Copilot for a week on a PR it had just reviewed properly (#656).
#
# So: among Copilot's reviews OF THIS HEAD, arm only when there is a refusal and no substantive
# review beside it. Same login/body recognition as its sibling - never a body match on humans.
function Test-CopilotOnlyRefused {
    param(
        [object[]]$Reviews,
        [string]$HeadSha = ''
    )
    $head = "$HeadSha".Trim()
    $refused = $false
    $substantive = $false
    foreach ($r in @($Reviews)) {
        $login = "$($r.author.login)"
        if ($login -notmatch $script:CopilotReviewerLoginPattern) { continue }
        if ($head -and "$($r.commit.oid)".Trim() -ne $head) { continue }
        if (Test-CopilotRefusalBody -Body "$($r.body)") { $refused = $true }
        else                                             { $substantive = $true }
    }
    return ($refused -and -not $substantive)
}

function Test-CopilotUnavailableReview {
    param(
        [object[]]$Reviews,
        [string]$HeadSha = ''
    )
    $head = "$HeadSha".Trim()
    foreach ($r in @($Reviews)) {
        $login = "$($r.author.login)"
        if ($login -notmatch $script:CopilotReviewerLoginPattern) { continue }
        if ($head -and "$($r.commit.oid)".Trim() -ne $head) { continue }
        if (Test-CopilotRefusalBody -Body "$($r.body)") {
            return $true
        }
    }
    return $false
}

# Given an owner's marker entry (or $null) and the current time, decide whether to SKIP Copilot.
# Skip while state is 'unavailable' and the cooldown (until) has not passed; an expired cooldown or a
# null entry means "try again". Pure — the gate passes Get-Date so this stays testable.
function Get-CopilotSkipDecision {
    param($Entry, [datetime]$Now)
    if (-not $Entry -or "$($Entry.state)" -ne 'unavailable') {
        return [pscustomobject]@{ Skip = $false; Until = $null; Reason = $null }
    }
    if ($Entry.until) {
        $until = [datetime]::Parse([string]$Entry.until, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($Now -ge $until) { return [pscustomobject]@{ Skip = $false; Until = $Entry.until; Reason = $Entry.reason } }  # cooldown expired -> retry
        return [pscustomobject]@{ Skip = $true; Until = $Entry.until; Reason = $Entry.reason }
    }
    return [pscustomobject]@{ Skip = $true; Until = $null; Reason = $Entry.reason }   # indefinite
}

# ── Marker I/O (side-effecting; $HOME-level, keyed by owner) ───────────────────

function Get-CopilotStatePath {
    if (-not $HOME) { return $null }
    $dir = Join-Path $HOME '.agentic-board'
    return (Join-Path $dir 'copilot-availability.json')
}

# Read the whole marker map (a pscustomobject). Empty object when absent/unreadable — a corrupt marker
# must never crash the gate, only mean "no memory yet".
function Read-CopilotState {
    $p = Get-CopilotStatePath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return [pscustomobject]@{} }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
}

function Get-CopilotOwnerEntry {
    param([Parameter(Mandatory)][string]$Owner)
    $state = Read-CopilotState
    if ($state.PSObject.Properties.Name -contains $Owner) { return $state.$Owner }
    return $null
}

# The gate's question: should I skip Copilot for this owner right now?
function Test-CopilotShouldSkip {
    param([Parameter(Mandatory)][string]$Owner, [datetime]$Now = (Get-Date))
    return (Get-CopilotSkipDecision -Entry (Get-CopilotOwnerEntry $Owner) -Now $Now)
}

# Persist "Copilot unavailable for <Owner> until <Until>". Best-effort: a write failure must not fail
# the gate (the gate still works, it just won't remember). Returns $true when written.
function Set-CopilotUnavailable {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][datetime]$Until,
        [string]$Reason = 'Copilot code review unavailable (quota/limit)',
        [datetime]$Now = (Get-Date)
    )
    $p = Get-CopilotStatePath
    if (-not $p) { return $false }
    try {
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $state = Read-CopilotState
        $entry = [pscustomobject]@{
            state      = 'unavailable'
            until      = $Until.ToUniversalTime().ToString('o')
            reason     = $Reason
            detectedAt = $Now.ToUniversalTime().ToString('o')
        }
        $state | Add-Member -NotePropertyName $Owner -NotePropertyValue $entry -Force
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
        return $true
    } catch { return $false }
}

# Forget the marker for one owner (the -EnableCopilot reset / cooldown-expiry cleanup).
function Clear-CopilotUnavailable {
    param([Parameter(Mandatory)][string]$Owner)
    $p = Get-CopilotStatePath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $false }
    try {
        $state = Read-CopilotState
        if ($state.PSObject.Properties.Name -notcontains $Owner) { return $false }
        $state.PSObject.Properties.Remove($Owner)
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
        return $true
    } catch { return $false }
}
