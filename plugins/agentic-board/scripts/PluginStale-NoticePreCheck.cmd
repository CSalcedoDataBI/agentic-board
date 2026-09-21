@echo off
rem PluginStale-NoticePreCheck.cmd (#714) - the cheap gate in front of the stale-plugin notice hook.
rem
rem The notice runs on UserPromptSubmit, i.e. before EVERY prompt of EVERY session, and it used to pay a
rem full pwsh interpreter start (about 2 s on the maintainer's machine, measured) even when nothing could
rem possibly have changed. Same problem, same cure as Brake-PreCheck.cmd (#572): answer the common case
rem in cmd and only start pwsh when it can matter.
rem
rem WHAT IT DOES
rem   1. Reads ONLY the first line of the payload (set /p) and takes the session id from it. The payload
rem      holds the user's prompt (& | < > ^ % ! and quotes), so it is never echoed, never put on a command
rem      line and never expanded outside delayed expansion (whose results cmd does not re-parse).
rem   2. Accepts the id only if it is exactly 36 characters of hex digits and dashes (a UUID, which is
rem      what Claude Code sends). Anything else -> exit 0, silently: the notice is advisory, so silence is
rem      the safe direction here (unlike the brake). An id that passes cannot contain a path separator, so
rem      it cannot name anything outside the stamp folder.
rem   3. Looks for this session's stamp: <home>\.agentic-board\plugin-check\<id>\installed_plugins.json, a
rem      byte-for-byte COPY of Claude's installed_plugins.json as the hook READ it at the start of its last
rem      CONCLUSIVE check. Unchanged since that check means the two files are identical (fc /b). Any
rem      update rewrites that file with different bytes (versions, commits, timestamps); comparing content
rem      rather than file times has no clock or resolution to get wrong, and it is one small process.
rem   4. Unchanged -> exit 0 without starting pwsh. Otherwise -> pwsh runs the real hook with -SessionId and
rem      the hook does the actual work. Its stdout (the systemMessage JSON) reaches Claude Code unchanged.
rem
rem FAIL DIRECTION: this shim can only ever SKIP work when the stamp provably matches the last conclusive
rem check for that same session. Any doubt (no stamp, an odd path, fc reporting a difference OR an error)
rem runs pwsh. An invalid id stays silent. A check that was inconclusive (session or
rem marker not there yet, installed list unreadable) never writes a stamp, so it is never remembered. It
rem always exits 0: a hook that exits non-zero shows an error to the user.
rem
rem Windows-only by design, like the rest of this plugin.
setlocal EnableExtensions EnableDelayedExpansion
set "LINE="
set /p "LINE="
if not defined LINE exit /b 0
set "REST=!LINE:*session_id=!"
set "REST=!REST:"=!"
set "REST=!REST: =!"
if not "!REST:~0,1!"==":" exit /b 0
set "ID=!REST:~1,36!"
set "LASTCHAR=!ID:~35,1!"
if not defined LASTCHAR exit /b 0
set "T=!ID!"
for %%C in (0 1 2 3 4 5 6 7 8 9 a b c d e f -) do if defined T set "T=!T:%%C=!"
if defined T exit /b 0
rem the id must END there: what follows the 36 characters (quotes and spaces are already gone) may only be
rem the end of the line, a comma or a closing brace. A 37th hex, dash, slash or any other character means this
rem is not a 36-character id (it would otherwise be truncated to a prefix that names another session).
set "NEXT=!REST:~37,1!"
if not defined NEXT goto idok
if "!NEXT!"=="," goto idok
if "!NEXT!"=="}" goto idok
exit /b 0
:idok
set "CFG=%CLAUDE_CONFIG_DIR%"
if not defined CFG set "CFG=%USERPROFILE%\.claude"
set "INST=%CFG%\plugins\installed_plugins.json"
set "SDIR=%USERPROFILE%\.agentic-board\plugin-check\!ID!"
set "SFILE=%SDIR%\installed_plugins.json"
if not exist "%INST%" goto run
if not exist "%SFILE%" goto run
rem Identical bytes = unchanged since that check. fc exits 0 only for identical files; 1 (different) and 2
rem (error, e.g. unreadable) both mean "not provably the same", so both fall through to pwsh.
fc /b "%INST%" "%SFILE%" >nul 2>&1
if errorlevel 1 goto run
exit /b 0
:run
pwsh -NoProfile -File "%~dp0PluginStale-NoticeHook.ps1" -SessionId !ID!
exit /b 0
