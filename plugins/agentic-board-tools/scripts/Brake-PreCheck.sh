#!/bin/sh
# Brake-PreCheck.sh (#572, #767) - the cheap gate in front of the PreToolUse brake hook.
#
# The hook runs before EVERY Bash/PowerShell/Edit/Write call of EVERY session, and a pwsh start
# alone costs about 2 s on Windows. Almost no session is brake-armed, so this answers the common
# case without starting pwsh: it looks for the brake marker in the working directory and its three
# parents - the same four places Brake-PreToolUseHook.ps1 starts from - and only when one exists
# does it hand stdin (the hook payload) to the real hook with exec.
#
# It ships in agentic-board-tools with every script of the suite (#768): agentic-board, the plugin
# listed in the directory, carries Markdown only.
#
# POSIX sh, so the same file runs everywhere Claude Code runs hooks: `sh -c` on macOS/Linux and
# Git Bash on Windows (it replaced Brake-PreCheck.cmd, which only ran on Windows).
#
# FAIL DIRECTION: with no marker it exits 0 (allow) - an ordinary session must never be slowed or
# blocked. With a marker, whatever the real hook decides is the answer, exit code included - and
# with a marker but no pwsh it DENIES (#764), and so it does when pwsh runs but the hook errors
# (#812): any exit other than 0 or 2 is a non-blocking error to Claude Code, which would let the
# tool call through, so the armed run would fail open.
#
# Launch (#812): hooks.json calls `sh "<root>/scripts/Brake-PreCheck.sh"`. Never `cmd /d /c "<root>"`:
# under Git Bash a forward-slash root like C:/Users/<name> reaches cmd.exe with "/<first letter>" read
# as a switch, and the hook never runs. tests/agentic-board/Hooks.Launch.Tests.ps1 runs every
# hooks.json line the way Claude Code does, with such a root.
#
# The walk climbs with ${d%/*} from $PWD instead of naming parent paths literally: the directory
# validator refuses a plugin command that spells a path above the plugin folder (#768), and this is
# the working directory's ancestry, not the plugin's. Parameter expansion, so no extra process.
d=$PWD
n=0
while [ "$n" -lt 4 ] && [ -n "$d" ]; do
  if [ -f "$d/.agentic-board/brake-armed.json" ]; then
    if ! command -v pwsh >/dev/null 2>&1; then
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BRAKE: this run is brake-armed but pwsh (PowerShell 7) is not on PATH, so the brake cannot decide. Refusing."}}'
      exit 0
    fi
    # Not exec (#812): if pwsh itself errors (the hook file missing, a crash before its own
    # try/catch), its exit code would be a non-blocking hook error and the armed call would pass.
    # Exit 0 or 2 is the real hook's answer and goes through unchanged; anything else is the
    # brake failing to run, which inside an armed run is a refusal, said out loud.
    out=$(pwsh -NoProfile -File "$(dirname "$0")/Brake-PreToolUseHook.ps1")
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
      [ -n "$out" ] && printf '%s\n' "$out"
      exit "$rc"
    fi
    printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"BRAKE: this run is brake-armed but the brake hook failed to run (pwsh exit $rc), so it cannot decide. Refusing.\"}}"
    exit 0
  fi
  [ "$d" = "/" ] && break
  d=${d%/*}
  [ -z "$d" ] && d=/
  n=$((n + 1))
done
exit 0
