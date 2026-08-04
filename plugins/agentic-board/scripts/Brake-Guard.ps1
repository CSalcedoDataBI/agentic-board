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

# `git` accepts GLOBAL options between the program and the subcommand - `git -C <path> push`,
# `git -c k=v push`, `git --no-pager push`. Anchoring rules on `\bgit\s+push\b` demanded that
# `push` follow `git` immediately, so ONE ordinary flag shook off every git rule at once (#542,
# review round 3). That included the branch-delete rules, which predate this work: the hole was
# never about the new patterns, it was about the anchor they all copied.
#
# Only FLAG-SHAPED tokens may sit in the gap, each with at most one value, so `git commit -m
# "push to main"` (quotes are stripped by then) is not mistaken for a push.
#
# The repetition is UNBOUNDED, and getting there took two wrong turns worth recording:
#
#   1. Capped at {0,5} "to avoid ReDoS". That WAS a bypass - six `-c` flags and the rule stopped
#      matching, and chaining several `-c` is ordinary scripting, not an attack.
#   2. Uncapped as `-{1,2}[^\s;|&]+`, on the reasoning (mine and the reviewer's) that the classes
#      are disjoint so no catastrophic backtracking is possible. MEASURED, AND FALSE: `--flag`
#      repeated 1000 times HUNG the matcher past three minutes. `-{1,2}` and `[^\s;|&]+` can both
#      consume the second dash, so every `--` token had two readings and 1000 of them had 2^1000.
#
# The form here removes that ambiguity: one leading `-`, then everything up to whitespace, so each
# token has exactly ONE reading. Measured after the change - 1000 `--flag` tokens: 3 ms with no
# match, 334 ms when a real push follows; 2000 `-c k=v` tokens: 3 ms. The bypass is closed without
# a count, and the stall is closed without a cap.
#
# The lesson, since this file keeps teaching it: "the classes are disjoint so it cannot blow up"
# is an argument, not a measurement. Time it.
$script:GitCmd = '\bgit\s+(?:-[^\s;|&]*\s+(?:[^\s;|&-][^\s;|&]*\s+)?)*'

# Command patterns that REACH an irreversible action, grouped by the contract's action vocabulary
# (the same words Expert-Autonomy uses, so one contract drives both).
#
# Every pattern is matched against a normalized command string (lowercased, whitespace collapsed).
# They are deliberately specific: a pattern that over-matches blocks legitimate work and the run
# stalls, which is how a safety control gets switched off for being annoying.
$script:BrakePatterns = @(
    # --- merge: putting work on the default branch ---------------------------------
    @{ action = 'merge';   pattern = '\bgh\s+pr\s+merge\b' }
    # The tool's own merge script. DENIED for every autonomous run, ordered or not.
    #
    # #536 briefly opened this one path for a run the owner had ordered to finish, on the reasoning
    # that this script re-checks the four conditions and refuses on its own. External review found
    # that opening it made two latent holes REACHABLE, and neither is a string-matching bug (#541):
    #
    #   - `cd C:\ ; pwsh <genuine-gate> -PR 42` passes here per segment, and the gate then resolves
    #     its marker from its RUNTIME cwd, finds none outside the worktree, and skips all four
    #     conditions. The two halves of the control disagreed about which directory the run was in,
    #     and the run got to pick.
    #   - The review condition is satisfied by a PR comment the run is able to post itself - the
    #     same self-certification the design had already removed for the TEST condition.
    #
    # So the path stays shut until #541 gives the gate a trustworthy armed context and evidence the
    # subject cannot mint. An ordered run still records the order in its marker; what it does not
    # get is a way to act on it. A control that opens a door on the strength of a check the caller
    # can walk around is the failure this file exists to stop.
    @{ action = 'merge';   pattern = '\bboard-merge\.ps1\b' }
    # The REST merge endpoints, recognized by the ENDPOINT rather than by the client that calls
    # it. Anchoring these to `gh api` (as the first cut did) left the identical request open via
    # curl, Invoke-RestMethod, python or node - all of which have the same token available.
    @{ action = 'merge';   pattern = '\bpulls?/\d+/merge\b' }
    @{ action = 'merge';   pattern = '\brepos/[^\s]+/merges\b' }

    # Pushing straight to the default branch (#542). The simplest merge route of all, and the one
    # this guard missed for longest: `git push origin HEAD:main` puts work on main with one command
    # and matched nothing. It was not quite an oversight - the delete pattern below carries a
    # comment calling `HEAD:main` "an ordinary push refspec" - but this file's own vocabulary
    # defines merge as "putting work on the default branch", which is exactly what it does.
    #
    # Two shapes: a REFSPEC landing on main/master (`HEAD:main`, `branch:main`, `+HEAD:main`,
    # `HEAD:refs/heads/main`), and pushing the default branch BY NAME (`git push origin main`).
    #
    # HOW THE BRANCH NAME MUST END - and this took three tries, each one a real defect:
    #
    #   `\b`        refused `main-cleanup` and `master.bak`. `\b` only asks that the next character
    #               not be a word character, so a `-` or a `.` satisfied it: legitimate branches
    #               blocked on the run's most common command. The tests missed it because the case
    #               they checked, `maintenance`, continues with `t` - a word character - so it
    #               passed for the WRONG REASON and proved nothing about `-`.
    #   `(\s|$)`    fixed that and reopened a different hole: it accepts only a space or the end of
    #               a segment, and $SegmentSeparator does not split on a lone `&` or a redirection.
    #               So `git push origin HEAD:main&` - background the push, same effect - matched
    #               nothing. The `\b` it replaced had caught that one.
    #   lookahead   what is here now: the branch name must end at whitespace, a shell separator, a
    #               redirection, or end-of-string. Both failure directions covered, and the
    #               terminator set is the shell's, not an ad-hoc one.
    #
    # LIMIT: this core is pure (no git access), so it cannot ask the repo what its default branch
    # is. A project whose default is neither `main` nor `master` is not covered.
    # The source side is `+`, not `*`, on purpose: an EMPTY source (`git push origin :main`) is
    # git's spelling for DELETING the remote branch, not for writing to it. Allowing zero characters
    # there made this rule swallow the delete - the array is walked in order, so the refusal told the
    # human "merge is marked irreversible" for a command that removes main, arguably the worse of
    # the two. Not a bypass (the contract filter runs per pattern, so a delete-braking contract
    # still refused it), but a control is only as useful as the account it gives of itself.
    @{ action = 'merge';   pattern = $script:GitCmd + 'push\b[^;&|<>]*\s\+?[^\s;|&]+:(?:refs/heads/)?(main|master)(?=[\s;&|<>]|$)' }
    @{ action = 'merge';   pattern = $script:GitCmd + 'push\b[^;&|<>]*\s(main|master)(?=[\s;&|<>]|$)' }

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
    @{ action = 'delete';  pattern = $script:GitCmd + 'push\b.*--delete\b' }
    # git's other remote-branch deletion syntax: `git push origin :branch`. The leading whitespace
    # in the lookbehind keeps `HEAD:main` (an ordinary push refspec) out of it.
    @{ action = 'delete';  pattern = $script:GitCmd + 'push\b[^;&|<>]*\s:\S' }

    # --- indirection through a variable ---------------------------------------------
    # Quote removal (see ConvertTo-NormalizedCommand) handles `gh pr 'merge'`, but a value the
    # shell only produces at runtime - `$verb='merge'; gh pr $verb 490` - is not visible to any
    # amount of string matching. Rather than pretend otherwise, refuse to let a HIGH-RISK CLIENT
    # take an unresolvable subcommand: an autonomous run has no legitimate need to reach `gh`
    # through a variable, and refusing is the safe side of a call this guard cannot make.
    @{ action = 'merge';   pattern = '\bgh\s+(pr|api|repo|release)\s+[$%]' }
    @{ action = 'merge';   pattern = '\bgh\s+[$%]' }
)

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

    THE OWNER'S END-TO-END ORDER IS NOT HONOURED HERE. It is recorded in the marker (#530) and
    read by the merge gate, but this classifier opens nothing for it: #536 tried, and external
    review showed that opening even the gate's own script made two latent holes reachable that no
    amount of string matching can close (#541). Until the gate carries a trustworthy armed context
    and evidence the run cannot mint, an ordered run is refused exactly like an unordered one.
#>
function Test-IsBrakedCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [string[]]$Irreversible = @()
    )
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
                # budgetMinutes: 0 (not enforced) unless the marker carries a positive integer.
                # A malformed value reads as 0 - the budget is a LIVENESS limit, not a safety
                # control, so its failure direction is open (see Get-BudgetState).
                $budgetMin = 0
                try { if ($null -ne $o.budgetMinutes) { $budgetMin = [Math]::Max(0, [int]$o.budgetMinutes) } } catch { $budgetMin = 0 }
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
                    budgetMinutes = $budgetMin
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
        [bool]$EndToEnd = $false,
        # The contract's maxMinutes, made ENFORCEABLE (#564): the PreToolUse hook computes elapsed
        # time from armedAt and, past this many minutes, refuses further work commands (handoff and
        # wrap-up stay allowed). 0 = no budget enforcement. Until this field, the 120-minute budget
        # existed only as a sentence in the brief - a limit nothing could apply.
        [int]$BudgetMinutes = 0
    )
    $irr = @($Irreversible | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($irr.Count -eq 0) { $irr = @('merge','deploy','refresh','publish','delete') }
    return ([ordered]@{
        issue        = $Issue
        irreversible = $irr
        endToEnd     = $EndToEnd
        armedAt      = $ArmedAt
        budgetMinutes = [Math]::Max(0, $BudgetMinutes)
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
        [bool]$EndToEnd = $false,
        [int]$BudgetMinutes = 0
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
            -Branch $Branch -HostName $HostName -EndToEnd $EndToEnd -BudgetMinutes $BudgetMinutes)
    return 'armed'
}

<#
    Is this run past its time budget? (#564)

    The contract's 120-minute budget was a sentence in the brief - Get-BudgetVerdict existed and
    nothing called it, so a runaway run had no wall-clock limit at all. The marker now carries
    budgetMinutes + armedAt, and this computes the verdict the hook enforces.

    FAIL DIRECTION - open, and deliberately the opposite of the brake: the budget is a LIVENESS
    limit (stop a runaway run), not a safety control (stop an irreversible action). A corrupt
    armedAt that denied every command would brick normal work to enforce a resource cap; instead,
    an unparsable/absent armedAt or a 0 budget reports not-enforced. The brake's own fail-closed
    behavior is untouched - it runs BEFORE the budget check in the hook. Pure.
#>
function Get-BudgetState {
    param(
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][datetime]$Now
    )
    $max = 0
    try { if ($null -ne $Marker.budgetMinutes) { $max = [Math]::Max(0, [int]$Marker.budgetMinutes) } } catch { $max = 0 }
    if ($max -le 0) {
        return @{ Enforced = $false; OverBudget = $false; ElapsedMinutes = 0; MaxMinutes = 0 }
    }
    $armed = $null
    try {
        $armed = [datetime]::ParseExact("$($Marker.armedAt)", 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    } catch { $armed = $null }
    if (-not $armed) {
        return @{ Enforced = $false; OverBudget = $false; ElapsedMinutes = 0; MaxMinutes = $max }
    }
    $elapsed = [int][Math]::Floor(($Now - $armed).TotalMinutes)
    return @{
        Enforced       = $true
        OverBudget     = ($elapsed -gt $max)
        ElapsedMinutes = $elapsed
        MaxMinutes     = $max
    }
}

# What an over-budget run is still allowed to do from a SHELL tool: save its state and leave.
# Everything here is reversible wrap-up - the brake patterns are checked BEFORE this exemption in
# the hook, so `git push origin HEAD:main` is still a refused merge, exempt list or not.
#
# Every pattern is ANCHORED to the start of the segment (external review, #564 round 1): matched
# anywhere, an exempt token became a free pass - `npm run build -- git status` contained "git
# status" and sailed through. The COMMAND must be the wrap-up, not merely mention one. The only
# permitted prefixes are the launcher shapes (`&`, `pwsh -File ...`) that genuinely execute the
# exempt script.
# The exact basename, preceded by nothing or a path separator (round 6): `\S*` before the name
# accepted any SUFFIX match, so `Evil-Board-Handoff.ps1` rode the exemption of the script it
# merely ends like.
# The handoff script must be invoked with -save (round 7): Board-Handoff.ps1 also exposes
# -Resume, which is the START of more work, not the end of it. The runledger's verbs are all
# wrap-up, so it carries no such constraint. The lookahead is safe against smuggling because an
# exempt segment is already required to be INERT (no ;, &, |, redirections or subexpressions).
$script:BudgetExemptHandoffSave = '(?=[^;|&]*\s-save\b)'
$script:BudgetExemptPatterns = @(
    ('^(?:& )?(?:[^\s;|&]*[\\/])?board-handoff\.ps1\b' + $script:BudgetExemptHandoffSave)
    '^(?:& )?(?:[^\s;|&]*[\\/])?board-runledger\.ps1(?=\s|$)'
    # Via a pwsh launcher: the exempt script must be the -File TARGET, and the prefix may carry
    # ONLY known non-executing host flags (round 5): "any flag-shaped token" admitted -Command,
    # and `pwsh -command build.ps1 -file ...board-handoff.ps1` executes build.ps1 with '-file ...'
    # as its ARGUMENTS - the -File this pattern trusted never reaches the host. Requiring -File
    # at all is the round-2 fix (a -Command string that merely MENTIONED the script was a free
    # pass); the closed flag list is what makes the -File the one the host actually honours.
    ('^(?:& )?(?:pwsh|powershell)\s+(?:(?:-noprofile|-nologo|-noninteractive|-mta|-sta|-executionpolicy\s+[^\s;|&]+)\s+)*-file\s+(?:[^\s;|&]*[\\/])?board-handoff\.ps1\b' + $script:BudgetExemptHandoffSave)
    '^(?:& )?(?:pwsh|powershell)\s+(?:(?:-noprofile|-nologo|-noninteractive|-mta|-sta|-executionpolicy\s+[^\s;|&]+)\s+)*-file\s+(?:[^\s;|&]*[\\/])?board-runledger\.ps1(?=\s|$)'
    ('^/board\s+handoff\b' + $script:BudgetExemptHandoffSave)      # the slash-command spelling
    # Wrap-up git takes NO global flags (round 6): the $script:GitCmd gap admitted `-c
    # diff.external=build.cmd`, and git then executes the configured helper - the exemption
    # became an execution primitive. The brake keeps the flag-tolerant matcher (it must not be
    # shaken off by a flag); the exemption is a positive allowlist and stays strict instead.
    '^git\s+(status|diff|log|add|commit|push)\b'
    # stash is SAVE-ONLY (round 4): pop/apply/branch mutate the worktree and drop/clear destroy
    # state - exactly the "more work / lost work" the budget exists to stop. Bare `git stash`
    # is push and stays allowed.
    '^git\s+stash(\s+(push|save)\b.*)?\s*$'
    '^gh\s+(pr|issue)\s+(comment|view)\b'                          # report where it stopped / read for the handoff
)

# True when an over-budget shell command is part of wrapping up rather than more work. Pure.
function Test-IsBudgetExemptCommand {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    # Backticks are checked on the RAW command (round 4): the normalizer strips them, so a Bash
    # substitution (`git status `npm run build``) normalized into text the anchored patterns
    # accept - the nested command would already have run by then. Conservative on purpose: a
    # PowerShell escape backtick in a message is rare in wrap-up commands and easy to rephrase.
    if ("$Command".Contains('`')) { return $false }
    $norm = ConvertTo-NormalizedCommand $Command
    if (-not $norm) { return $false }
    # EVERY segment must be exempt: `Board-Handoff.ps1 -Save; npm run build` is more work wearing
    # a handoff as a hat - the same per-segment rule the brake itself applies, in reverse.
    $sawSegment = $false
    foreach ($segment in ($norm -split $script:SegmentSeparator)) {
        $seg = $segment.Trim()
        if (-not $seg) { continue }
        if ($seg -match $script:SegmentSeparator -and $seg.Length -le 2) { continue }
        $sawSegment = $true
        # An exempt PREFIX must not smuggle more work in the same segment (round 3): the splitter
        # does not split on a lone `&`, and redirections / subexpressions ride inside the segment
        # - `git status & npm run build`, `git status > src/app.ts`, `git commit -m $(npm run
        # build)` all began with wrap-up and carried work. An exempt segment must be INERT: no
        # background operator, no redirection, no subexpression. A LEADING `& ` is PowerShell's
        # call operator - part of the launcher shape the patterns accept - so only that one is
        # stripped before the check. The cost is a conservative refusal of, say, a commit message
        # containing '&' - the deny message says how to rephrase. Parentheses are refused too
        # (round 4): `git status (npm run build)` / `@(npm run build)` are PowerShell execution
        # forms that survive normalization, and no wrap-up command needs them.
        if (($seg -replace '^&\s+', '') -match '[&<>()]') { return $false }
        $segExempt = $false
        foreach ($p in $script:BudgetExemptPatterns) {
            if ($seg -match $p) { $segExempt = $true; break }
        }
        if (-not $segExempt) { return $false }
    }
    return $sawSegment
}

# Writes an over-budget run may still make: the handoff surfaces and the run's own state dir.
# `..` anywhere in the path refuses outright (external review, #564 round 1): this core is pure
# (no filesystem), so it cannot resolve `C:\repo\.handoffs\..\src\app.ts` - and no legitimate
# wrap-up write ever needs a parent-directory hop. Refusing the shape closes the escape without
# needing the resolution.
#
# With -Root (the armed worktree, derived from the marker's own location), the surfaces are
# anchored to the ROOT rather than matched anywhere in the path (round 6): unanchored,
# `C:\repo\src\.agentic-board\app.ts` passed because a directory NAME appeared mid-path. Without
# a root (no marker context) the anywhere-match remains as the conservative fallback.
function Test-IsBudgetExemptWrite {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string]$Root = ''
    )
    if (-not "$Path".Trim()) { return $false }
    $p = "$Path" -replace '\\', '/'
    if ($p -match '(^|/)\.\.(/|$)') { return $false }
    $surfaces = '(?i)^(HANDOFF\.md|active-handoff\.md|MEMORY\.md)$|^\.handoffs(/|$)|^\.agentic-board(/|$)|^evidence/[^/]+\.md$'
    $r = "$Root".Trim() -replace '\\', '/'
    if ($r) {
        $r = $r.TrimEnd('/')
        if (-not $p.StartsWith("$r/", [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        return [bool](($p.Substring($r.Length + 1)) -match $surfaces)
    }
    return [bool]($p -match '(?i)(^|/)(HANDOFF\.md|active-handoff\.md)$|(^|/)\.handoffs(/|$)|(^|/)\.agentic-board(/|$)|(^|/)MEMORY\.md$|(^|/)evidence/[^/]+\.md$')
}

# The deny payload for an over-budget command: instructive, not punitive - it names the exact
# wrap-up sequence that is still allowed.
function New-BudgetDenyJson {
    param(
        [int]$Issue = 0,
        [int]$ElapsedMinutes = 0,
        [int]$MaxMinutes = 0
    )
    $issueClause = if ($Issue -gt 0) { " (issue #$Issue)" } else { "" }
    $reason = "BUDGET: refused - this autonomous run$issueClause has spent $ElapsedMinutes of its " +
              "$MaxMinutes-minute budget. The budget is enforced mechanically, not advisory (#564). " +
              "Wrap up now - these are still allowed: commit and push your WIP, run " +
              "'/board handoff -Save' (Board-Handoff.ps1) to persist the resume state, close the " +
              "run ledger, and leave a PR/issue comment saying where you stopped. Then STOP and " +
              "report. Do not start new work; if more time is genuinely needed, the human relaunches " +
              "with a fresh budget."
    return (@{ hookSpecificOutput = @{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'deny'
        permissionDecisionReason = $reason
    } } | ConvertTo-Json -Depth 5 -Compress)
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






