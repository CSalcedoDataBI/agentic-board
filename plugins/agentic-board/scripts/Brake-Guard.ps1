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
    @{ action = 'merge';   pattern = '\bboard-merge\.ps1\b' }
    # gh api against the REST merge endpoints (pulls/<n>/merge, /merges)
    @{ action = 'merge';   pattern = '\bgh\s+api\b.*\bpulls?/\d+/merge\b' }
    @{ action = 'merge';   pattern = '\bgh\s+api\b.*\brepos/[^\s]+/merges\b' }

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
    @{ action = 'delete';  pattern = '\bgh\s+api\b.*--method\s+delete\b' }
    @{ action = 'delete';  pattern = '\bgit\s+push\b.*--delete\b' }
)

# A command that only PREVIEWS the action mutates nothing, so denying it buys no safety and
# costs the run its ability to inspect what it is about to hand the human.
$script:DryRunPattern = '(^|\s)(-dryrun|-whatif|--dry-run)(\s|$)'

# Normalize so patterns can stay readable: lowercase, tabs/newlines/runs of spaces -> one space.
function ConvertTo-NormalizedCommand {
    param([string]$Command)
    if (-not $Command) { return '' }
    return ($Command -replace '\s+', ' ').Trim().ToLowerInvariant()
}

<#
    Decide whether $Command reaches an irreversible action that this run's contract brakes on.

    Returns the matched action name ('merge', 'deploy', ...) or '' when the command is allowed.
    $Irreversible is the contract's own list, so a contract that does NOT mark 'merge' as
    irreversible does not get its merges denied - the control follows the contract, it does not
    invent policy.
#>
function Test-IsBrakedCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [string[]]$Irreversible = @()
    )
    $norm = ConvertTo-NormalizedCommand $Command
    if (-not $norm) { return '' }
    if ($norm -match $script:DryRunPattern) { return '' }

    $irr = @($Irreversible | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($irr.Count -eq 0) { return '' }

    foreach ($p in $script:BrakePatterns) {
        if ($irr -notcontains $p.action) { continue }
        if ($norm -match $p.pattern) { return $p.action }
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
                if ($o.irreversible) { $irr = @($o.irreversible) }
                return @{
                    issue        = if ($o.issue) { [int]$o.issue } else { 0 }
                    irreversible = $irr
                    armedAt      = "$($o.armedAt)"
                    path         = $candidate
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
        [string]$HostName = ''
    )
    $irr = @($Irreversible | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($irr.Count -eq 0) { $irr = @('merge','deploy','refresh','publish','delete') }
    return ([ordered]@{
        issue        = $Issue
        irreversible = $irr
        armedAt      = $ArmedAt
        branch       = $Branch
        host         = $HostName
        note         = 'Written by /board expert auto. Removing this file disarms the brake for this worktree.'
    } | ConvertTo-Json -Depth 5)
}

# Where the marker lives for a given worktree (the caller ensures .agentic-board/ exists).
function Get-BrakeMarkerPath {
    param([Parameter(Mandatory)][string]$WorkPath)
    return (Join-Path (Join-Path $WorkPath '.agentic-board') $script:BrakeMarkerName)
}

# The PreToolUse deny payload, verbatim per the hook contract: exit 0 with this on stdout.
function New-BrakeDenyJson {
    param(
        [Parameter(Mandatory)][string]$Action,
        [int]$Issue = 0,
        [switch]$Unreadable
    )
    $issueClause = if ($Issue -gt 0) { " for issue #$Issue" } else { "" }
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
