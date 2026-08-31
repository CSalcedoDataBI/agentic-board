<#  Compact-PreCompactHook.ps1 - snapshot the transcript before a compaction (epic #348).

    Wired as a Claude Code PreCompact hook. It is the belt-and-suspenders half of the
    compaction-survival feature: the run-ledger (Board-RunLedger.ps1) is the primary
    recovery path, but if it ever has a gap, the raw transcript is preserved here so
    nothing is truly lost.

    Contract (all three matter):
      * NEVER blocks the compaction - it emits no `decision`, so compaction proceeds.
      * NEVER throws - a failing PreCompact hook would disrupt the session, so
        everything is wrapped and the script always exits 0.
      * OFFLINE + cheap - it only copies a local file (the transcript) into the repo's
        `.agentic-board/compact-snapshots/`; no network, no gh.

    Dot-source guard: set $env:ABIOS_PRECOMPACT_DOTSOURCE=1 to load the pure helper for
    Pester without reading stdin or touching the filesystem.
#>
[CmdletBinding()]
param()

# Colon-free basic-format ISO-8601 UTC stamp + trigger, for a snapshot filename
# (':' is invalid on Windows). Pure: the caller passes the clock and the trigger.
function New-CompactSnapshotName([datetime]$when, [string]$trigger) {
    $t = if ($trigger -match '^[A-Za-z]+$') { $trigger.ToLower() } else { 'unknown' }
    return ($when.ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-$t.jsonl")
}

# ==============================================================================
# Main. Dot-source guard for tests.
# ==============================================================================
if ($env:ABIOS_PRECOMPACT_DOTSOURCE) { return }

try {
    if (-not [Console]::IsInputRedirected) { exit 0 }

    $raw = ""
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = "" }
    $in = $null
    if ($raw) { try { $in = $raw | ConvertFrom-Json } catch { $in = $null } }
    if (-not $in) { exit 0 }

    $transcript = if ($in.transcript_path) { [string]$in.transcript_path } else { "" }
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

    $cwd = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
    $root = git -C $cwd rev-parse --show-toplevel 2>$null
    if (-not $root) { $root = $cwd }

    $snapDir = Join-Path (Join-Path $root '.agentic-board') 'compact-snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Force $snapDir | Out-Null }

    $trigger = if ($in.trigger) { [string]$in.trigger } else { 'unknown' }
    $name = New-CompactSnapshotName (Get-Date) $trigger
    Copy-Item -LiteralPath $transcript -Destination (Join-Path $snapDir $name) -Force
}
catch {
    # A PreCompact hook must never fail the session - swallow everything.
}
exit 0
