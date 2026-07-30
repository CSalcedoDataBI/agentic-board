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

$marker = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop

    # Shell tools can reach an irreversible action; the file-writing tools can reach the MARKER,
    # which is the same thing one step earlier. Read/Glob/Grep cannot do either.
    $toolName = "$($payload.tool_name)"
    $shellTools = @('Bash', 'PowerShell')
    $writeTools = @('Edit', 'Write', 'NotebookEdit')
    if ($toolName -notin ($shellTools + $writeTools)) { exit 0 }

    $cwd = "$($payload.cwd)"
    if (-not $cwd) { $cwd = (Get-Location).Path }

    . (Join-Path $PSScriptRoot 'Brake-Guard.ps1')
    $marker = Read-BrakeMarker -StartDir $cwd
    if (-not $marker) { exit 0 }   # not an armed run -> never interfere

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
    if ($marker) {
        try {
            Write-Output (New-BrakeDenyJson -Action 'merge' -Issue $marker.issue -Unreadable)
        } catch {
            # Last resort: the literal deny payload, built without any helper that could fail.
            Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BRAKE: refused - brake-armed run and the guard could not evaluate this command. Stop at a reviewed PR and leave irreversible actions to the human."}}'
        }
    }
    exit 0
}
