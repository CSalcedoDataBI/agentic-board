#!/bin/sh
# Brake-PreCheck.sh (#572, #767) - the cheap gate in front of the PreToolUse brake hook.
#
# The hook runs before EVERY Bash/PowerShell/Edit/Write call of EVERY session, and a pwsh start
# alone costs about 2 s on Windows. Almost no session is brake-armed, so this answers the common
# case without starting pwsh: it looks for the brake marker in the working directory and its three
# parents - the same four places Brake-PreToolUseHook.ps1 starts from - and only when one exists
# does it hand stdin (the hook payload) to the real hook with exec.
#
# POSIX sh, so the same file runs everywhere Claude Code runs hooks: `sh -c` on macOS/Linux and
# Git Bash on Windows (it replaced Brake-PreCheck.cmd, which only ran on Windows).
#
# FAIL DIRECTION: with no marker it exits 0 (allow) - an ordinary session must never be slowed or
# blocked. With a marker, whatever the real hook decides is the answer, exit code included - and
# with a marker but no pwsh it DENIES (#764): exec failing would exit 127, which Claude Code treats
# as a non-blocking error and lets the tool call through, so the armed run would fail open.
for d in . .. ../.. ../../..; do
  if [ -f "$d/.agentic-board/brake-armed.json" ]; then
    if ! command -v pwsh >/dev/null 2>&1; then
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BRAKE: this run is brake-armed but pwsh (PowerShell 7) is not on PATH, so the brake cannot decide. Refusing."}}'
      exit 0
    fi
    exec pwsh -NoProfile -File "$(dirname "$0")/Brake-PreToolUseHook.ps1"
  fi
done
exit 0
