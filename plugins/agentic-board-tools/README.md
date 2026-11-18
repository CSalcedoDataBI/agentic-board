# agentic-board-tools

The scripts and hooks of [agentic-board](https://github.com/CSalcedoDataBI/agentic-board).
agentic-board itself is Markdown only (commands, skills, agents): every script its commands run,
the presets they apply and every hook live here. Install both.

## Install

```
/plugin marketplace add CSalcedoDataBI/agentic-board
/plugin install agentic-board@agentic-board
/plugin install agentic-board-tools@agentic-board
```

Start a new session after installing. Requirements:
[PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
(`pwsh`), `git`, the [`gh` CLI](https://cli.github.com/), and `sh` (Git Bash on Windows).

This plugin is installed from this repository's own marketplace only; it is not listed in the
Anthropic plugin directory.

## How agentic-board finds the scripts

A `SessionStart` hook (`scripts/Tools-Root.sh`) writes this plugin's folder to
`~/.agentic-board/tools-root` and, when Claude Code offers it, exports `AGENTIC_BOARD_TOOLS` for the
session. agentic-board's commands read either one and run `<that folder>/scripts/<name>.ps1`.
Scripts that need agentic-board's own files (the diagram theme, say) find that plugin next to this
one, or through Claude Code's `installed_plugins.json`.

## Hooks

| Hook | What it does |
|---|---|
| `SessionStart` | Writes the pointer to this plugin's folder (above). |
| `SessionStart` (startup) | A one-time welcome banner. |
| `SessionStart` (startup, resume) | Removes *empty* orphan folders under the current repo's `.claude/worktrees/`. |
| `SessionStart` (compact) | A one-line notice when a saved `/board` handoff exists. |
| `PreToolUse` (Bash, PowerShell, Edit, Write, NotebookEdit, MultiEdit) | Refuses merge, deploy, publish and delete commands **only** inside a worktree that an autonomous run armed with a brake marker. A POSIX `sh` precheck answers every other call without starting `pwsh`. |
| `UserPromptSubmit` | Tells you when a plugin this session loaded has been updated on disk. |
| `PreCompact` | Appends one line (time, repo, session id, transcript path and size) to `~/.claude/agentic-board/compact-markers.jsonl`. |

A run armed with the brake (`/board work ... -StopAtPR`, or one with a time budget) refuses to
launch unless this plugin is installed and enabled, rather than run unbraked.

What the scripts run, send and fetch is listed in
[agentic-board's README](https://github.com/CSalcedoDataBI/agentic-board/blob/main/plugins/agentic-board/README.md)
and its [PRIVACY.md](https://github.com/CSalcedoDataBI/agentic-board/blob/main/plugins/agentic-board/PRIVACY.md).

## License

MIT. See [LICENSE](LICENSE).
