<#  Handoff-SessionStartHook.ps1 - surface a saved handoff when a session begins.

    Meant to be wired as a Claude Code SessionStart hook (OPT-IN - see
    skills/projects-admin/references/handoff-hook.md). When RESUMING a prior session
    (source == "resume") it looks for a local HANDOFF.md at the current repo root and, if
    present, emits a one-line `additionalContext` so the assistant immediately knows there
    is a handoff to resume - without the user remembering the command. (A fresh startup is
    covered by the self-cleaning MEMORY.md pointer from -Save; see #141.)

    Read-only and OFFLINE by design: a SessionStart hook runs on every session, so it must
    be fast. It only reads the local HANDOFF.md mirror (never hits the network); the durable
    board comment is fetched by `Board-Handoff.ps1 -Resume`, not here.

    It NEVER blocks and NEVER throws - a failing SessionStart hook would disrupt startup, so
    everything is wrapped and the script always exits 0.

    Dot-source guard: set $env:ABIOS_HANDOFF_HOOK_DOTSOURCE=1 to load the pure helper for
    Pester without reading stdin or touching the filesystem.
#>
[CmdletBinding()]
param()

# Build the SessionStart context line from a HANDOFF.md body. Pure + testable.
# Returns "" when the body is empty (nothing to surface).
function Get-HandoffSessionContext([string]$body) {
    if (-not $body -or $body.Trim() -eq "") { return "" }
    $issue = if ($body -match '(?m)^issue:\s*(\S+)\s*$') { $Matches[1] } else { "" }
    $saved = if ($body -match '(?m)^saved:\s*(\S+)\s*$') { $Matches[1] } else { "" }
    # First non-empty line under "## Next concrete step".
    $next = ""
    $lines = @($body -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*##\s+Next concrete step\s*$') {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j].Trim() -ne "") { $next = ($lines[$j] -replace '^\s*\[[V?]\]\s*', '').Trim(); break }
            }
            break
        }
    }
    $who = if ($issue -and $issue -ne "null") { "issue #$issue" } else { "this repo" }
    $when = if ($saved) { ", saved $saved" } else { "" }
    $ctx = "A saved /board handoff exists for $who$when (HANDOFF.md at the repo root)."
    if ($next) { $ctx += " Next step: $($next.TrimEnd('.'))." }
    $ctx += " Run 'Board-Handoff.ps1 -Resume' to rehydrate the full context (traps, drift, the durable board comment)."
    return $ctx
}

# Build the SessionStart context line AFTER an auto-compaction (source == "compact"),
# from the local active-run marker object (.agentic-board/active-run.json). Pure +
# testable. Returns "" unless a run is genuinely active - so the compact case is a
# strict no-op on any session that is not mid-run (safe to ship always-on). It only
# re-injects a POINTER: the durable ledger lives in the epic comment, which the
# reawakened agent re-reads in-session (the hook itself never hits the network).
function Get-CompactSessionContext($marker) {
    if (-not $marker) { return "" }
    $status = if ($marker.PSObject.Properties.Name -contains 'status') { [string]$marker.status } else { "" }
    if ($status -ne 'active') { return "" }
    $epic = if ($marker.PSObject.Properties.Name -contains 'epic') { [int]$marker.epic } else { 0 }
    if ($epic -le 0) { return "" }
    $board = if ($marker.PSObject.Properties.Name -contains 'board') { [int]$marker.board } else { 0 }
    $repo  = if ($marker.PSObject.Properties.Name -contains 'repo')  { [string]$marker.repo } else { "" }
    $queue = @()
    if ($marker.PSObject.Properties.Name -contains 'queue' -and $marker.queue) {
        $queue = @($marker.queue | ForEach-Object { "#$_" })
    }
    $ctx = "You just auto-compacted mid-run of a /board work queue (epic #$epic"
    if ($board -gt 0) { $ctx += ", board #$board" }
    $ctx += "). The durable run-ledger lives in the '[abios-run-ledger]' comment on epic #$epic"
    if ($repo) { $ctx += " ($repo)" }
    $ctx += " - re-read it with 'gh issue view $epic --comments' to recover decisions and the next step."
    if ($queue.Count) { $ctx += " Queue: $($queue -join ', ')." }
    $ctx += " Re-read each issue's live status from the board before resuming."
    return $ctx
}

# ==============================================================================
# Main. Dot-source guard for tests.
# ==============================================================================
if ($env:ABIOS_HANDOFF_HOOK_DOTSOURCE) { return }

try {
    # If stdin is not redirected (e.g. the script was run by hand), there is no hook
    # payload to read and ReadToEnd() would block forever - bail out immediately.
    if (-not [Console]::IsInputRedirected) { exit 0 }

    $raw = ""
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = "" }
    $in = $null
    if ($raw) { try { $in = $raw | ConvertFrom-Json } catch { $in = $null } }

    $source = if ($in -and $in.source) { [string]$in.source } else { "" }
    # Two cases surface context; everything else (a fresh startup, a clear) is a no-op:
    #   resume  -> a stale HANDOFF.md exists to resume (self-cleaning MEMORY.md pointer
    #              covers a plain new session, see #141).
    #   compact -> an auto-compaction just happened MID-RUN of a /board work queue; the
    #              generic summary drops the thread, so re-inject a pointer to the durable
    #              run-ledger (epic #348). Strict no-op unless a run is active.
    if ($source -ne 'resume' -and $source -ne 'compact') { exit 0 }

    $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
    $root = git -C $cwd rev-parse --show-toplevel 2>$null
    if (-not $root) { $root = $cwd }

    $ctx = ""
    if ($source -eq 'compact') {
        # OFFLINE by design: read only the local marker (never the network). The state
        # dir is shared across worktrees via the main clone's .git-common-dir; here we
        # only need the per-repo `.agentic-board/active-run.json` under the repo root.
        $markerPath = Join-Path (Join-Path $root '.agentic-board') 'active-run.json'
        if (-not (Test-Path $markerPath)) {
            # Fall back to the pre-rebrand dir name so a mid-migration repo still works.
            $markerPath = Join-Path (Join-Path $root '.agentic-bi-ops') 'active-run.json'
        }
        if (-not (Test-Path $markerPath)) { exit 0 }
        $marker = $null
        try { $marker = Get-Content $markerPath -Raw | ConvertFrom-Json } catch { $marker = $null }
        $ctx = Get-CompactSessionContext $marker
    } else {
        $handoffPath = Join-Path $root 'HANDOFF.md'
        if (-not (Test-Path $handoffPath)) { exit 0 }
        $body = Get-Content $handoffPath -Raw
        $ctx = Get-HandoffSessionContext $body
    }
    if (-not $ctx) { exit 0 }

    $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress
    Write-Output $out
}
catch {
    # A SessionStart hook must never fail the session - swallow everything.
}
exit 0
