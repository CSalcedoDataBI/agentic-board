<#
.SYNOPSIS
    PreToolUse hook: refuse an irreversible command inside a brake-armed autonomous run (#516).

.DESCRIPTION
    Reads the PreToolUse payload on stdin, and when the current working directory sits inside a
    worktree that `/board expert auto` armed (a .agentic-board/brake-armed.json marker exists),
    denies commands that would merge / deploy / refresh / publish / delete.

    This is the half of the brake that does not depend on the agent's cooperation. The briefing
    still asks the session to stop at a reviewed PR; this refuses the call if it asks anyway.

    FAIL DIRECTION, chosen deliberately:
      - No marker found (an ordinary human session, or any session outside an armed worktree)
        -> allow, always. A safety control that interferes with normal work gets removed.
      - Marker found, anything after that goes wrong -> DENY. Inside an armed run, a hook that
        breaks must not silently hand back the capability it exists to remove. That is exactly
        how the previous prose brake failed: it reported ARMED while enforcing nothing.

    Contract (Claude Code hooks): stdin is JSON with .tool_name, .tool_input.command and .cwd.
    Exit 0 with no stdout = no decision (normal permission flow). Exit 0 with the
    hookSpecificOutput/permissionDecision=deny payload = blocked.
#>
[CmdletBinding()]
param()

# No `throw` on stray native stderr: this runs on every tool call and must be quiet.
$ErrorActionPreference = 'Continue'

# The literal deny payload, built with no helper that could itself fail. Everything below can
# fall back to this, which is what makes "fail closed inside an armed run" true rather than
# aspirational.
$script:HardDeny = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BRAKE: refused - this is a brake-armed autonomous run and the guard could not evaluate this command. Stop at a reviewed PR and leave merge/deploy/publish/delete to the human."}}'

# Minimal, dependency-free probe for the armed state. This runs BEFORE Brake-Guard.ps1 is loaded
# ON PURPOSE: if the armed flag were only set after that dot-source, a failure to load the guard
# would leave the catch believing the run was unarmed and silently allow everything - the exact
# fail-open this control exists to remove.
function Test-ArmedFast {
    param([string]$StartDir)
    $dir = $StartDir
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $dir '.agentic-board') 'brake-armed.json')) { return $true }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $false
}

$armed  = $false
$marker = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop

    # Shell tools can reach an irreversible action; the file-writing tools can reach the MARKER,
    # which is the same thing one step earlier. Read/Glob/Grep cannot do either.
    $toolName = "$($payload.tool_name)"
    $shellTools = @('Bash', 'PowerShell')
    # MultiEdit belongs here too: it is a file-writing path like the others, and leaving it out
    # left one uncovered route to the marker. Listing a tool this harness may not expose costs
    # nothing; omitting one it does expose costs the whole control.
    $writeTools = @('Edit', 'Write', 'NotebookEdit', 'MultiEdit')
    if ($toolName -notin ($shellTools + $writeTools)) { exit 0 }

    $cwd = "$($payload.cwd)"
    if (-not $cwd) { $cwd = (Get-Location).Path }

    # Establish armed-or-not FIRST, with no dependencies. Everything after this point may fail;
    # this flag is what decides which way it fails.
    $armed = Test-ArmedFast -StartDir $cwd
    if (-not $armed) { exit 0 }    # not an armed run -> never interfere

    . (Join-Path $PSScriptRoot 'Brake-Guard.ps1')
    $marker = Read-BrakeMarker -StartDir $cwd
    if (-not $marker) { Write-Output $script:HardDeny; exit 0 }  # armed, but unreadable -> refuse

    if ($toolName -in $writeTools) {
        # Rewriting the marker disarms the run just as effectively as deleting it - emptying its
        # list, or pointing it at nothing. Editing it is never part of the task.
        $target = "$($payload.tool_input.file_path)"
        if ($target -and ($target -replace '\\', '/') -match '(?i)brake-armed\.json$') {
            Write-Output (New-BrakeDenyJson -Action 'tamper' -Issue $marker.issue)
        }
        exit 0
    }

    $command = "$($payload.tool_input.command)"
    $action  = Test-IsBrakedCommand -Command $command -Irreversible $marker.irreversible
    if (-not $action) { exit 0 }

    Write-Output (New-BrakeDenyJson -Action $action -Issue $marker.issue)
    exit 0
} catch {
    # Inside an armed run, an error means we could not prove the command safe -> refuse.
    # $armed is set by the dependency-free probe above, so this holds even when the failure was
    # loading Brake-Guard.ps1 itself.
    if ($armed) {
        try {
            Write-Output (New-BrakeDenyJson -Action 'merge' -Issue $(if ($marker) { $marker.issue } else { 0 }) -Unreadable)
        } catch {
            Write-Output $script:HardDeny
        }
    }
    exit 0
}

