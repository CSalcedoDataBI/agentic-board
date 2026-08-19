<#  Worktree-SessionStartHook.ps1 - sweep empty orphan worktree directories at session start (#618).

    WHY A HOOK AND NOT A COMMAND. These orphans are born from abnormal session termination, so
    the moment a new session starts is exactly when the previous one's wreckage is on disk and
    nothing is using it. Waiting for someone to remember to run the doctor is what let a repo
    accumulate them for a week.

    WHAT IT TOUCHES. Only directories under `.claude/worktrees/` in the CURRENT repo that git
    does not know about AND that contain zero files. Never a worktree git still lists, never one
    with content. The removal is non-recursive, so a directory that gained a file between the
    check and the delete simply survives - the filesystem is the guard, not this script's timing.

    Everything else - orphans WITH content, and stale entries in the machine-wide registry - is
    left for `/board doctor` to report, because deciding those needs a human.

    A SessionStart hook that fails would disrupt startup, so every path is wrapped and the script
    always exits 0. Silence is the normal outcome: context is emitted only when something was
    actually removed.

    Dot-source guard: set $env:ABIOS_WORKTREE_HOOK_DOTSOURCE=1 to load the pure helpers for
    Pester without reading stdin or touching the filesystem.
#>
[CmdletBinding()]
param()

# Should this source run the sweep? Startup and resume both follow a previous session's exit,
# which is precisely when wreckage exists. `compact` is the same live session continuing - its
# worktrees are in use, so sweeping there would be pure risk for no gain.
function Test-ShouldSweepWorktrees {
    param([string]$Source)
    return $Source -in @('startup', 'resume')
}

# The message shown after a sweep. Pure so a test can pin the wording without a filesystem.
# Names the count and the paths: a silent delete of something a human never knew existed is
# how a "cleanup" becomes indistinguishable from data loss in someone's memory.
function Get-SweepContext {
    param([string[]]$Removed = @())
    if (-not $Removed -or @($Removed).Count -eq 0) { return '' }
    $n = @($Removed).Count
    $list = ($Removed | ForEach-Object { "  - $_" }) -join "`n"
    @"
agentic-board removed $n empty orphan worktree director$(if ($n -eq 1) { 'y' } else { 'ies' }) left
behind by a previous session. Each was absent from 'git worktree list' and contained zero files;
the delete was non-recursive, so nothing with content could have been touched.

$list

Mention this to the user in one short line, then continue with their request.
"@
}

if ($env:ABIOS_WORKTREE_HOOK_DOTSOURCE) { return }

try {
    # No redirected stdin (run by hand) -> no hook payload; bail before ReadToEnd blocks.
    if (-not [Console]::IsInputRedirected) { exit 0 }

    $raw = ""
    try { $raw = [Console]::In.ReadToEnd() } catch { $raw = "" }
    $in = $null
    if ($raw) { try { $in = $raw | ConvertFrom-Json } catch { $in = $null } }

    $source = if ($in -and $in.source) { [string]$in.source } else { "" }
    if (-not (Test-ShouldSweepWorktrees $source)) { exit 0 }

    $cwd = if ($in -and $in.cwd) { [string]$in.cwd } else { (Get-Location).Path }

    # Only act inside a git repo - outside one there is no managed worktree directory to sweep.
    $inRepo = (& git -C $cwd rev-parse --is-inside-work-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or "$inRepo".Trim() -ne 'true') { exit 0 }

    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot 'Worktree-Ghosts.ps1')
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = ''

    $ghosts = @(Get-WorktreeGhosts -RepoRoot $cwd | Where-Object { $_.AutoRemovable })
    if ($ghosts.Count -eq 0) { exit 0 }

    $removed = @()
    foreach ($g in $ghosts) {
        if (Remove-EmptyWorktreeOrphan -Path $g.Path) { $removed += $g.Path }
    }
    if ($removed.Count -eq 0) { exit 0 }

    $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = (Get-SweepContext $removed) } } |
        ConvertTo-Json -Compress
    Write-Output $out
}
catch {
    # A SessionStart hook must never fail the session - swallow everything.
}
exit 0
