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

# Does a reviews list show Copilot answering that it could NOT review (no quota / unavailable)? The bot
# posts this as a COMMENTED review by copilot-pull-request-reviewer. With -HeadSha, only a refusal
# bound to THAT commit counts (#563): a stale refusal from an earlier commit is not an answer to the
# current request, and letting it renew the full cooldown suppressed the 1-day silence path the gate
# uses for a request that got no answer at all. Without -HeadSha the old any-refusal behavior holds. Pure.
function Test-CopilotUnavailableReview {
    param(
        [object[]]$Reviews,
        [string]$HeadSha = ''
    )
    $head = "$HeadSha".Trim()
    foreach ($r in @($Reviews)) {
        $login = "$($r.author.login)"
        if ($login -notmatch '(?i)copilot') { continue }
        if ($head -and "$($r.commit.oid)".Trim() -ne $head) { continue }
        if ("$($r.body)" -match '(?i)unable to review|quota limit|reached their quota|not available|no seats|isn''t available') {
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
