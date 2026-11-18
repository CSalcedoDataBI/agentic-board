#!/bin/sh
# Tools-Root.sh (#768) - tell the agentic-board skills where this plugin's scripts are.
#
# agentic-board, the plugin listed in the directory, ships Markdown only: its skills and commands
# run the scripts of THIS plugin, agentic-board-tools, which Claude Code installs in a versioned
# cache folder that a skill cannot know in advance. On every session start this writes that folder,
# one line, to ~/.agentic-board/tools-root, and the skills read it from there.
#
# POSIX sh, no pwsh: it runs on every session start. It prints nothing and always exits 0 (a failed
# write only means the skills say "install agentic-board-tools" until the next start).
root=${CLAUDE_PLUGIN_ROOT:-}
[ -n "$root" ] || exit 0
home_dir=${HOME:-$USERPROFILE}
[ -n "$home_dir" ] || exit 0
dir="$home_dir/.agentic-board"
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s\n' "$root" > "$dir/tools-root.tmp" 2>/dev/null && mv -f "$dir/tools-root.tmp" "$dir/tools-root" 2>/dev/null
# Also for this session's shell commands: Claude Code applies what a SessionStart hook writes to
# CLAUDE_ENV_FILE. The value is single-quoted with any quote in it escaped, so it stays data.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  q=$(printf '%s' "$root" | sed "s/'/'\\\\''/g")
  printf "export AGENTIC_BOARD_TOOLS='%s'\n" "$q" >> "$CLAUDE_ENV_FILE" 2>/dev/null
fi
exit 0
