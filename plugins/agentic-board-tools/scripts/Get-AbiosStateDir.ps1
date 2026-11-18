<#  Get-AbiosStateDir.ps1 — the SINGLE resolver for the internal state directory.

    Dot-source this file (never invoke it): `. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')`
    then call `Get-AbiosStateDir`.

    The state dir holds live per-repo state (sessions.json, briefings, handoffs,
    fleet/*.json). It was historically named `.agentic-bi-ops/`; after the rebrand
    (agentic-bi-ops -> agentic-board) the canonical name is `.agentic-board/`.

    This resolver is the ONLY place either literal appears. It gives every caller:
      1. the NEW name (`.agentic-board/`) going forward,
      2. a one-time SILENT migration of an existing `.agentic-bi-ops/` (rename in place),
      3. a FALLBACK to the old dir if the rename can't happen (e.g. a file is locked
         by a running session) — so no state is ever orphaned or lost.

    Root resolution:
      -Root <path>  base dir the state dir lives under (used by callers that already
                    know their root: a passed -Root, or $HOME for global backups).
      (omitted)     resolved from the MAIN clone's .git via `git rev-parse
                    --git-common-dir`, so every worktree of the repo shares one dir.
                    Returns $null outside a git repo.

    -NoCreate       don't create a fresh empty dir when neither name exists (read-only
                    callers that only want the path to Test-Path). Migration of an
                    existing old dir still happens — moving real state is always safe.  #>
[CmdletBinding()]
param()

function Get-AbiosStateDir {
    [CmdletBinding()]
    param(
        [string]$Root,
        [switch]$NoCreate
    )

    if (-not $Root) {
        $common = git rev-parse --git-common-dir 2>$null
        if (-not $common) { return $null }
        try { $Root = Split-Path (Resolve-Path $common).Path -Parent } catch { return $null }
    }

    $new = Join-Path $Root '.agentic-board'
    $old = Join-Path $Root '.agentic-bi-ops'

    # One-time silent migration: old state exists, new doesn't -> move it in place.
    # The rename can fail two ways, and they need opposite handling:
    #   - a CONCURRENT session (parallel worktree fleet) already migrated it: $new
    #     now exists and $old is gone -> use $new, or we'd resurrect a split brain.
    #   - a real LOCK (a live session holds a file): $old is still there -> fall back
    #     to it in place; a later call self-heals once the lock clears. No state lost.
    if ((Test-Path $old) -and -not (Test-Path $new)) {
        try { Rename-Item -LiteralPath $old -NewName '.agentic-board' -ErrorAction Stop }
        catch {
            if (Test-Path $new) { return $new }   # someone else won the migration
            if (Test-Path $old) { return $old }   # genuine lock -> use old in place
            # both gone (old moved out from under us) -> fall through, create $new
        }
    }

    if (-not (Test-Path $new)) {
        if ($NoCreate) { return $new }
        New-Item -ItemType Directory -Force $new | Out-Null
    }
    return $new
}
