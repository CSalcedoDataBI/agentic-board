#!/bin/sh
# PluginStale-NoticePreCheck.sh (#714, #767) - the cheap gate in front of the stale-plugin notice hook.
#
# The notice runs on UserPromptSubmit, i.e. before EVERY prompt of EVERY session, and a pwsh start
# alone costs about 2 s on Windows. This answers the common case without starting pwsh. POSIX sh,
# so it runs where Claude Code runs hooks: `sh -c` on macOS/Linux, Git Bash on Windows (it replaced
# PluginStale-NoticePreCheck.cmd, which only ran on Windows).
#
# WHAT IT DOES
#   1. Reads ONLY the first line of the payload and takes the session id from it. The payload holds
#      the user's prompt, so it is never evaluated, never put on a command line, only matched.
#   2. Accepts the id only if it is exactly 36 characters of hex digits and dashes (a UUID) followed
#      by a JSON delimiter. Anything else -> exit 0, silently: the notice is advisory. An id that
#      passes cannot contain a path separator, so it cannot name anything outside the stamp folder.
#   3. Compares Claude's installed_plugins.json with this session's stamp - a byte-for-byte copy taken
#      at the hook's last CONCLUSIVE check (cmp). Identical -> nothing changed -> exit 0, no pwsh.
#   4. Otherwise pwsh runs the real hook with -SessionId; its stdout (the systemMessage JSON) is
#      passed through unchanged.
#
# FAIL DIRECTION: it only skips work when the stamp provably matches. Any doubt (no stamp, no
# installed list, cmp reporting a difference or an error) runs pwsh. It always exits 0: a hook that
# exits non-zero shows an error to the user.
IFS= read -r line || [ -n "$line" ] || exit 0
case "$line" in *session_id*) ;; *) exit 0 ;; esac
rest=${line#*session_id}
rest=$(printf '%s' "$rest" | tr -d '" ')
case "$rest" in :*) ;; *) exit 0 ;; esac
rest=${rest#:}
id=$(printf '%s' "$rest" | cut -c1-36)
[ ${#id} -eq 36 ] || exit 0
case "$id" in *[!0-9a-f-]*) exit 0 ;; esac
next=$(printf '%s' "$rest" | cut -c37)
case "$next" in ''|,|'}') ;; *) exit 0 ;; esac

home_dir=${HOME:-$USERPROFILE}
cfg=${CLAUDE_CONFIG_DIR:-$home_dir/.claude}
inst="$cfg/plugins/installed_plugins.json"
stamp="$home_dir/.agentic-board/plugin-check/$id/installed_plugins.json"
if [ -f "$inst" ] && [ -f "$stamp" ] && cmp -s "$inst" "$stamp"; then
  exit 0
fi
pwsh -NoProfile -File "$(dirname "$0")/PluginStale-NoticeHook.ps1" -SessionId "$id"
exit 0
