<#  Compact-PreCompactHook.ps1 - mark where a compaction happened (epic #348, #737).

    Wired as a Claude Code PreCompact hook. It is the belt-and-suspenders half of the
    compaction-survival feature: the run-ledger (Board-RunLedger.ps1) is the primary
    recovery path; this records WHERE the raw transcript is, so a gap can still be recovered.

    It used to COPY the whole transcript into <repo>/.agentic-board/compact-snapshots/. Two
    problems, both measured (#737): the copy is a verbatim duplicate of the file Claude Code
    already keeps in ~/.claude/projects (compaction appends, it does not truncate) - 1.7 GB of
    duplicates on one machine - and it carries the entire context window, global CLAUDE.md
    included, into a repo folder one `git add -f` away from being published. Nothing ever read
    those copies back. It now appends ONE small line to <ClaudeHome>/agentic-board/
    compact-markers.jsonl: when, why, which repo, which session, and the transcript path + size.
    Nothing is written inside the repo.

    Contract (all three matter):
      * NEVER blocks the compaction - it emits no `decision`, so compaction proceeds.
      * NEVER throws - a failing PreCompact hook would disrupt the session, so
        everything is wrapped and the script always exits 0.
      * OFFLINE + cheap - one appended line; no network, no gh, no copy.

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

# The marker line: a pointer to the transcript, never a copy of it. Pure.
function New-CompactMarker {
    param([datetime]$When, [string]$Trigger, [string]$Repo, [string]$SessionId, [string]$Transcript, [long]$Bytes = 0)
    $t = if ($Trigger -match '^[A-Za-z]+$') { $Trigger.ToLower() } else { 'unknown' }
    [pscustomobject]@{
        at = $When.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
        trigger = $t; repo = $Repo; sessionId = $SessionId; transcript = $Transcript; transcriptBytes = $Bytes
    }
}

# ==============================================================================
# Main. Dot-source guard for tests.
# ==============================================================================
if ($env:ABIOS_PRECOMPACT_DOTSOURCE) { return }

try {
    if (-not [Console]::IsInputRedirected) { exit 0 }

    $raw = ""
    try { $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false)).ReadToEnd() } catch { $raw = "" }
    $in = $null
    if ($raw) { try { $in = $raw | ConvertFrom-Json } catch { $in = $null } }
    if (-not $in) { exit 0 }

    $transcript = if ($in.transcript_path) { [string]$in.transcript_path } else { "" }
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }

    $cwd = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).Path }
    # Never invent a directory: a cwd that does not exist (a mis-decoded path) must not become one.
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)   # git prints UTF-8 paths; the default OEM decode garbles them (#682)
    $root = git -C $cwd rev-parse --show-toplevel 2>$null
    if (-not $root) { $root = $cwd }

    # Outside every repo, in the Claude home (CLAUDE_CONFIG_DIR when set, as Claude Code does).
    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' }
    $markerDir = Join-Path $claudeHome 'agentic-board'
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Force $markerDir | Out-Null }

    $trigger = if ($in.trigger) { [string]$in.trigger } else { 'unknown' }
    $sid = if ($in.session_id) { [string]$in.session_id } else { [IO.Path]::GetFileNameWithoutExtension($transcript) }
    $bytes = 0L; try { $bytes = (Get-Item -LiteralPath $transcript).Length } catch { }
    $line = New-CompactMarker -When (Get-Date) -Trigger $trigger -Repo ([string]$root).Trim() -SessionId $sid -Transcript $transcript -Bytes $bytes |
        ConvertTo-Json -Compress
    [IO.File]::AppendAllText((Join-Path $markerDir 'compact-markers.jsonl'), $line + "`n", [Text.UTF8Encoding]::new($false))
}
catch {
    # A PreCompact hook must never fail the session - swallow everything.
}
exit 0
