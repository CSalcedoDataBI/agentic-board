<#
.SYNOPSIS
    The irreversible brake, as a mechanical control (#440 / #516).

.DESCRIPTION
    `/board expert auto` brakes on the irreversible - merge, deploy, refresh, publish, delete.
    Until now that brake was PROSE: a paragraph in the launch briefing asking the session not to
    merge. An observed run merged its own PR anyway, and the brake reported itself ARMED the whole
    time. Instruction alone is what drifted; the answer is a backstop that does not depend on the
    agent's cooperation.

    This file is that backstop's pure core. `Start-WorktreeSession` ARMS a run by writing a
    marker into the launched worktree; a PreToolUse hook (Brake-PreToolUseHook.ps1) reads the
    marker and REFUSES the tool call before it executes. The session cannot talk its way past a
    control it never gets to run.

    POLARITY - deliberately the opposite of Expert-Autonomy.Test-IsIrreversible, and the
    difference matters:

      Expert-Autonomy classifies an ACTION NAME ('merge', 'deploy') from a closed vocabulary, so
      an unknown verb fails SAFE -> treated as irreversible, stop and ask.

      This file classifies an arbitrary SHELL COMMAND STRING. The space of harmless commands is
      unbounded, so failing safe here would deny everything and the run could not work at all.
      It therefore recognizes SPECIFIC dangerous invocations and denies only those; anything
      unrecognized passes through to the normal permission flow.

    Consequence, stated plainly rather than papered over: this is a backstop against the known
    irreversible paths, not a sandbox. A novel way to reach the same effect is not caught here.
    The complementary controls are #517 (the supervisor detects a violation after the fact) and
    #518 (auto-clean refuses to destroy the evidence).

    Pure (no side effects) behind a dot-source guard ($env:ABIOS_BRAKEGUARD_DOTSOURCE).

.EXAMPLE
    . .\Brake-Guard.ps1 ; Test-IsBrakedCommand -Command 'gh pr merge 490' -Irreversible @('merge')
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# The file a brake-armed run drops in its worktree. Named as state, not config: it is written at
# launch and read by the hook, the supervisor (#517) and the teardown (#518).
$script:BrakeMarkerName = 'brake-armed.json'

# Command patterns that REACH an irreversible action, grouped by the contract's action vocabulary
# (the same words Expert-Autonomy uses, so one contract drives both).
#
# Every pattern is matched against a normalized command string (lowercased, whitespace collapsed).
# They are deliberately specific: a pattern that over-matches blocks legitimate work and the run
# stalls, which is how a safety control gets switched off for being annoying.
$script:BrakePatterns = @(
    # --- merge: putting work on the default branch ---------------------------------
    @{ action = 'merge';   pattern = '\bgh\s+pr\s+merge\b' }
    # GATED (#536): this script is the only merge path that CHECKS anything - it establishes the
    # four end-to-end conditions and exits 1 when any is unmet. So it is the one pattern an
    # ORDERED run may reach; every other route below stays shut. Marking it here rather than
    # special-casing the string in Test-IsBrakedCommand keeps "which paths are gated" a property
    # of the pattern table, where the next person will actually look.
    #
    # The DENY pattern stays broad on purpose - any invocation by that name is a merge attempt and
    # is refused for an unordered run. What the order opens is narrower: see $GatedMergePattern.
    @{ action = 'merge';   pattern = '\bboard-merge\.ps1\b'; gated = $true }
    # The REST merge endpoints, recognized by the ENDPOINT rather than by the client that calls
    # it. Anchoring these to `gh api` (as the first cut did) left the identical request open via
    # curl, Invoke-RestMethod, python or node - all of which have the same token available.
    @{ action = 'merge';   pattern = '\bpulls?/\d+/merge\b' }
    @{ action = 'merge';   pattern = '\brepos/[^\s]+/merges\b' }

    # --- publish: making something public / cutting a release -----------------------
    @{ action = 'publish'; pattern = '\bgh\s+release\s+create\b' }
    @{ action = 'publish'; pattern = '\bnpm\s+publish\b' }
    @{ action = 'publish'; pattern = '\bdotnet\s+nuget\s+push\b' }
    @{ action = 'publish'; pattern = '\btwine\s+upload\b' }

    # --- deploy ---------------------------------------------------------------------
    @{ action = 'deploy';  pattern = '\bwrangler\s+(deploy|publish)\b' }
    @{ action = 'deploy';  pattern = '\bvercel\s+(deploy\b|.*--prod\b)' }
    @{ action = 'deploy';  pattern = '\bnetlify\s+deploy\b' }
    @{ action = 'deploy';  pattern = '\baz\s+webapp\s+up\b' }

    # --- refresh: Fabric / Power BI dataset refreshes --------------------------------
    @{ action = 'refresh'; pattern = '\baz\s+rest\b.*\brefreshes\b' }
    @{ action = 'refresh'; pattern = '\binvoke-powerbirestmethod\b.*\brefreshes\b' }

    # --- delete: destroying remote state --------------------------------------------
    @{ action = 'delete';  pattern = '\bgh\s+repo\s+delete\b' }
    @{ action = 'delete';  pattern = '\bgh\s+(issue|release)\s+delete\b' }
    # Every spelling gh accepts for the same DELETE request, not just the long one.
    @{ action = 'delete';  pattern = '\bgh\s+api\b.*(--method[=\s]+delete\b|-x\s+delete\b)' }
    @{ action = 'delete';  pattern = '\bgit\s+push\b.*--delete\b' }
    # git's other remote-branch deletion syntax: `git push origin :branch`. The leading whitespace
    # in the lookbehind keeps `HEAD:main` (an ordinary push refspec) out of it.
    @{ action = 'delete';  pattern = '\bgit\s+push\b[^;]*\s:\S' }

    # --- indirection through a variable ---------------------------------------------
    # Quote removal (see ConvertTo-NormalizedCommand) handles `gh pr 'merge'`, but a value the
    # shell only produces at runtime - `$verb='merge'; gh pr $verb 490` - is not visible to any
    # amount of string matching. Rather than pretend otherwise, refuse to let a HIGH-RISK CLIENT
    # take an unresolvable subcommand: an autonomous run has no legitimate need to reach `gh`
    # through a variable, and refusing is the safe side of a call this guard cannot make.
    @{ action = 'merge';   pattern = '\bgh\s+(pr|api|repo|release)\s+[$%]' }
    @{ action = 'merge';   pattern = '\bgh\s+[$%]' }
)

# Compare paths the way two spellings of the same path should compare: case-insensitively, with
# both separators treated alike. Used only for the gated-path identity check below.
function ConvertTo-ComparablePath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return '' }
    return ($Path -replace '\\', '/').Trim().ToLowerInvariant()
}

# A command that only PREVIEWS the action mutates nothing, so denying it buys no safety and
# costs the run its ability to inspect what it is about to hand the human.
#
# Evaluated PER SEGMENT, never over the whole command line. Applied globally it was itself the
# bypass: `echo --dry-run; gh pr merge 490` contains a dry-run token, so the guard waved through
# a real merge sitting in the next segment.
$script:DryRunPattern = '(^|\s)(-dryrun|-whatif|--dry-run)(\s|$)'

# ...and only for commands that HAVE a preview mode. The token alone is not enough: it can appear
# inside an unrelated argument, and treating that as a preview whitelisted a real merge -
# `curl -H "X-Test: --dry-run" -X PUT .../pulls/12/merge` mutates exactly as much as it would
# without the header. A preview claim is only honoured from something that can actually preview.
$script:PreviewCapablePatterns = @(
    '\S+\.ps1\b'            # this tool's own scripts take -DryRun / -WhatIf
    '\bnpm\s+publish\b'     # npm publish --dry-run
)

# True only when the segment BOTH carries a preview flag and is a command that can honour one.
function Test-IsGenuinePreview {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Segment)
    if ($Segment -notmatch $script:DryRunPattern) { return $false }
    foreach ($p in $script:PreviewCapablePatterns) {
        if ($Segment -match $p) { return $true }
    }
    return $false
}

# Tampering with the marker is denied on its own terms, NOT gated on the contract's list: the
# marker is what makes the contract enforceable, so "may I disarm the brake?" is never a question
# the braked run gets to answer. Deleting a local file is otherwise allowed, which is exactly how
# `rm .agentic-board/brake-armed.json` would have turned the whole control off in one command.
$script:TamperPatterns = @(
    '\bbrake-armed\.json\b'
    # Destroying the state DIRECTORY takes the marker with it. The negative lookahead keeps this
    # to the directory itself: `rm .agentic-board/briefing-99.txt` is ordinary housekeeping and
    # must stay allowed, or the guard starts breaking the run's normal work.
    '\b(rm|del|erase|rd|rmdir|remove-item)\b[^;]*\.agentic-board(?![\\/]\S)'
    '\b(rm|del|erase|rd|rmdir|remove-item)\b[^;]*\.agentic-bi-ops(?![\\/]\S)'
)

# Shell separators that start a NEW command. Splitting on these is what makes the per-segment
# evaluation above sound: each segment is judged on its own, so a harmless prefix cannot vouch
# for what follows it.
$script:SegmentSeparator = '(;|&&|\|\||\||\r?\n)'

# Normalize so patterns can stay readable: lowercase, runs of whitespace -> one space.
#
# Newlines become an explicit ';' FIRST. Collapsing them into spaces (as the first cut did) welded
# a multi-line script into a single segment, and one `-DryRun` on line 1 then vouched for a real
# `gh pr merge` on line 2 - the same bypass the per-segment split exists to close.
function ConvertTo-NormalizedCommand {
    param([string]$Command)
    if (-not $Command) { return '' }
    # Line continuations are JOINED FIRST, before newlines become separators. The shell runs
    # `gh pr \<newline>merge 490` as one command; splitting on that newline handed the guard two
    # harmless-looking halves and let the merge through. Backslash for sh, backtick for PowerShell.
    $joined = $Command -replace '(\\|`)[ \t]*\r?\n[ \t]*', ' '
    $withBreaks = $joined -replace '\r?\n', ' ; '
    # Quote characters are removed the way the shell removes them, so `gh pr 'merge' 490` and
    # `gh "pr" merge 490` normalize to the same text the patterns already recognize. Without this
    # the classifier could be stepped around with nothing more exotic than a pair of quotes.
    $unquoted = $withBreaks -replace "[`"'``]", ''
    return ($unquoted -replace '\s+', ' ').Trim().ToLowerInvariant()
}

<#
    Decide whether $Command reaches an irreversible action that this run's contract brakes on.

    Returns the matched action name ('merge', 'deploy', ...) or '' when the command is allowed.
    $Irreversible is the contract's own list, so a contract that does NOT mark 'merge' as
    irreversible does not get its merges denied - the control follows the contract, it does not
    invent policy.

    $EndToEnd is the owner's ORDER to finish this run (#530, honoured here since #536). It does
    not lift the brake: it opens the GATED path only. `Board-Merge.ps1` weighs the four conditions
    and refuses on its own when they are unmet, so an ordered run reaches a merge only through the
    thing that can still say no. Raw `gh pr merge`, the REST endpoints and the variable-indirection
    patterns stay denied, which makes ordering the run NARROW the route to a merge rather than
    widen it. Defaults to $false so a caller that has not been taught about the order cannot
    accidentally grant it.

    $GatedScriptPath is the absolute path of the REAL gate, supplied by the caller that knows it
    (the hook passes its own sibling `Board-Merge.ps1`). Review caught why a pattern cannot stand
    in for it: matching the FILENAME let an ordered run - which has full write access to its own
    worktree - drop any file called `board-merge.ps1` with none of the four conditions in it and
    invoke that. Matching a canonical-looking PATH was no better, and worse, wrong: the installed
    plugin lives at `<version>/scripts/Board-Merge.ps1`, with no `plugins/agentic-board/` in it, so
    a path pattern would have refused the genuine gate in every project except this repo itself.
    Identity has to come from the caller, not from the shape of a string.

    Empty $GatedScriptPath means NO bypass at all: a caller that cannot say which script is the
    real one does not get to open one. That is the safe direction and keeps every existing caller
    (and every test that omits it) on the fully-braked behaviour.

    STATED LIMIT, since this file is a backstop and not a sandbox: an ordered run that OVERWRITES
    the real gate before invoking it still passes here, because the path is then genuine. Pinning
    the gate's content is tracked separately; the controls that catch it meanwhile are the review
    gate (a modified gate lands in the diff) and the post-hoc supervisor.
#>
function Test-IsBrakedCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [string[]]$Irreversible = @(),
        [bool]$EndToEnd = $false,
        [string]$GatedScriptPath = ''
    )
    $gate = ConvertTo-ComparablePath $GatedScriptPath
    $norm = ConvertTo-NormalizedCommand $Command
    if (-not $norm) { return '' }

    # Protecting the control comes before consulting the contract - see $script:TamperPatterns.
    foreach ($t in $script:TamperPatterns) {
        if ($norm -match $t) { return 'tamper' }
    }

    $irr = @($Irreversible | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($irr.Count -eq 0) { return '' }

    # One shell invocation can carry several commands. Judge each on its own, so a harmless
    # segment never licenses the one after it.
    foreach ($segment in ($norm -split $script:SegmentSeparator)) {
        $seg = $segment.Trim()
        if (-not $seg) { continue }
        if ($seg -match $script:SegmentSeparator -and $seg.Length -le 2) { continue }  # the separator itself
        if (Test-IsGenuinePreview -Segment $seg) { continue }                          # this segment only
        foreach ($p in $script:BrakePatterns) {
            if ($irr -notcontains $p.action) { continue }
            # An ORDERED run may reach the gated path - and only the script the CALLER identified
            # as the real one. Matching the bare filename here let a run invoke a look-alike it
            # had just written itself; no $gate means no bypass.
            if ($EndToEnd -and $p.gated -and $gate -and
                ((ConvertTo-ComparablePath $seg) -like "*$gate*")) { continue }
            if ($seg -match $p.pattern) { return $p.action }
        }
    }
    return ''
}

<#
    Find the brake marker for a working directory, walking up to the filesystem root.

    The hook fires in EVERY session, including the human's own. Only a directory inside a
    brake-armed worktree has the marker, so an ordinary session is never affected - that is the
    whole reason the marker is a file in the worktree rather than a machine-level setting.

    Returns a hashtable with the marker's fields, or $null when there is none.
#>
function Read-BrakeMarker {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StartDir)
    if (-not $StartDir) { return $null }
    $dir = $StartDir
    while ($dir) {
        $candidate = Join-Path (Join-Path $dir '.agentic-board') $script:BrakeMarkerName
        if (Test-Path -LiteralPath $candidate) {
            try {
                $raw = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
                $o = $raw | ConvertFrom-Json -ErrorAction Stop
                $irr = @()
                if ($o.irreversible) { $irr = @($o.irreversible | Where-Object { "$_".Trim() }) }
                # An armed marker with nothing in its list brakes on nothing - which is the same
                # as no brake at all, reached by overwriting the file with `{}`. A present marker
                # always means armed; fall back to the full vocabulary rather than to silence.
                $tampered = $false
                if ($irr.Count -eq 0) {
                    $irr = @('merge','deploy','refresh','publish','delete')
                    $tampered = $true
                }
                return @{
                    issue        = if ($o.issue) { [int]$o.issue } else { 0 }
                    irreversible = $irr
                    # Only a real JSON boolean `true` counts as the order. `[bool]$o.endToEnd`
                    # would have accepted the STRING "false" - PowerShell casts any non-empty
                    # string to $true - so a malformed or hand-edited marker granted the very
                    # permission this field exists to withhold. Absent, null or any other shape
                    # reads as NOT ordered: a run that predates this mode never received it.
                    endToEnd     = ($o.endToEnd -is [bool] -and $o.endToEnd)
                    armedAt      = "$($o.armedAt)"
                    path         = $candidate
                    emptied      = $tampered
                }
            } catch {
                # An unreadable marker must not silently disable the brake. Treat it as armed
                # with the default vocabulary: a corrupt safety file is not a licence to merge.
                return @{
                    issue        = 0
                    irreversible = @('merge','deploy','refresh','publish','delete')
                    armedAt      = ''
                    path         = $candidate
                    unreadable   = $true
                }
            }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

<#
    Build the marker a brake-armed run drops in its worktree.

    Kept pure (returns the JSON string; the caller writes it) so the armed contents are testable
    without spawning a session. `irreversible` is copied from the run's contract rather than
    hardcoded, so the guard and the briefing can never disagree about what this run brakes on.
#>
function New-BrakeMarkerJson {
    param(
        [Parameter(Mandatory)][int]$Issue,
        [string[]]$Irreversible = @(),
        [string]$ArmedAt = '',
        [string]$Branch = '',
        [string]$HostName = '',
        # Did the human ORDER this run end-to-end? Recorded here because the permission belongs to
        # the instruction that launched the run, not to a setting on disk that could be edited
        # afterwards - and because the merge decision happens later, when this file is the only
        # thing that still remembers what was asked for (#530).
        [bool]$EndToEnd = $false
    )
    $irr = @($Irreversible | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($irr.Count -eq 0) { $irr = @('merge','deploy','refresh','publish','delete') }
    return ([ordered]@{
        issue        = $Issue
        irreversible = $irr
        endToEnd     = $EndToEnd
        armedAt      = $ArmedAt
        branch       = $Branch
        host         = $HostName
        note         = 'Written by /board expert auto. Removing this file disarms the brake for this worktree.'
    } | ConvertTo-Json -Depth 5)
}

# Where the marker lives for a given worktree.
function Get-BrakeMarkerPath {
    param([Parameter(Mandatory)][string]$WorkPath)
    return (Join-Path (Join-Path $WorkPath '.agentic-board') $script:BrakeMarkerName)
}

<#
    Arm or DISARM a worktree, and report which happened.

    Both directions matter. Arming is obvious; disarming is the one that was missing: a worktree
    reused from an earlier braked run still holds its marker, so the hook would go on refusing
    merges for a run whose contract no longer brakes on them - while the launcher printed
    'Brake OFF'. The state on disk has to follow the contract in both directions or the message
    is a lie again.

    Returns 'armed', 'disarmed', or 'none' (nothing to disarm). Throws if it cannot write.
#>
function Set-BrakeArmedState {
    param(
        [Parameter(Mandatory)][string]$WorkPath,
        [Parameter(Mandatory)][bool]$Armed,
        [int]$Issue = 0,
        [string[]]$Irreversible = @(),
        [string]$Branch = '',
        [string]$HostName = '',
        [string]$ArmedAt = '',
        [bool]$EndToEnd = $false
    )
    $path = Get-BrakeMarkerPath -WorkPath $WorkPath
    if (-not $Armed) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            return 'disarmed'
        }
        return 'none'
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $path -Encoding UTF8 -Value (
        New-BrakeMarkerJson -Issue $Issue -Irreversible $Irreversible -ArmedAt $ArmedAt `
            -Branch $Branch -HostName $HostName -EndToEnd $EndToEnd)
    return 'armed'
}

# The PreToolUse deny payload, verbatim per the hook contract: exit 0 with this on stdout.
function New-BrakeDenyJson {
    param(
        [Parameter(Mandatory)][string]$Action,
        [int]$Issue = 0,
        [switch]$Unreadable
    )
    $issueClause = if ($Issue -gt 0) { " for issue #$Issue" } else { "" }
    if ($Action -eq 'tamper') {
        $reason = "BRAKE: refused - this command would remove or alter the brake marker of a " +
                  "brake-armed autonomous run$issueClause. Disarming your own safety control is " +
                  "never part of the task. Leave the marker alone; if the brake is genuinely " +
                  "wrong here, stop and say so to the human instead of removing it."
        return (@{ hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        } } | ConvertTo-Json -Depth 5 -Compress)
    }
    $why = if ($Unreadable) {
        "its brake marker is present but unreadable, so the brake is treated as ARMED"
    } else {
        "'$Action' is marked irreversible in this run's contract"
    }
    $reason = "BRAKE: refused - this is a brake-armed autonomous run$issueClause and $why. " +
              "Stop at 'PR ready + review gate green' and leave the $Action to the human. " +
              "This is a mechanical control, not a preference: do not look for another way to " +
              "perform the same action. If the human explicitly asked for it, they can run it " +
              "themselves or disarm the run."
    $payload = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        }
    }
    return ($payload | ConvertTo-Json -Depth 5 -Compress)
}

# Dot-source guard: tests set $env:ABIOS_BRAKEGUARD_DOTSOURCE to load the pure core only.
if ($env:ABIOS_BRAKEGUARD_DOTSOURCE) { return }






