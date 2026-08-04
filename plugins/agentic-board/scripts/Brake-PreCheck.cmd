@echo off
rem Brake-PreCheck.cmd (#572) - the cheap gate in front of the brake hook.
rem
rem The PreToolUse hook fires on EVERY Bash/PowerShell/Edit/Write call in EVERY session, and it
rem used to pay a full pwsh interpreter spawn (~1.3s measured on this machine) just to discover
rem that no brake marker exists - which is the case for every session except a launched
rem autonomous run. At 100 tool calls per session that was ~2 minutes of pure interpreter
rem startup, paid by every user in every repo. This cmd shim answers the common case in ~0.25s:
rem no marker anywhere near the working directory -> exit 0 without ever starting pwsh.
rem
rem The walk covers the working directory and three ancestors - the marker lives at the armed
rem WORKTREE ROOT, and hook processes start in the directory the session was launched from,
rem which for a launched run IS that root (deeper launches are covered by the ancestor steps).
rem Windows-only by design, like the rest of this plugin (wt/pwsh launchers throughout).
rem
rem FAIL DIRECTION: if the marker IS found, the full PowerShell hook runs and keeps its own
rem fail-closed behavior - this shim can only ever skip work for UNARMED sessions; an armed
rem worktree always reaches the real guard. stdin passes through to pwsh untouched.
if exist ".agentic-board\brake-armed.json" goto run
if exist "..\.agentic-board\brake-armed.json" goto run
if exist "..\..\.agentic-board\brake-armed.json" goto run
if exist "..\..\..\.agentic-board\brake-armed.json" goto run
exit /b 0
:run
pwsh -NoProfile -File "%~dp0Brake-PreToolUseHook.ps1"
exit /b %errorlevel%
