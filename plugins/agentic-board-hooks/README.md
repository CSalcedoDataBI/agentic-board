# agentic-board-hooks

Optional hooks for [agentic-board](https://github.com/CSalcedoDataBI/agentic-board). agentic-board
itself ships no hooks, so it does nothing until you type a command. This companion plugin adds
the hooks back for people who want them. A run armed with the brake (`/board work ... -StopAtPR`,
or one with a time budget) **requires** this plugin: without it, the launcher refuses to start the
session rather than run it unbraked.

## Install

```
/plugin marketplace add CSalcedoDataBI/agentic-board
/plugin install agentic-board@agentic-board
/plugin install agentic-board-hooks@agentic-board
```

Requirements: agentic-board installed, [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
(`pwsh`), and `sh` (Git Bash on Windows).

## What it runs

Every hook calls `scripts/Invoke-BoardHook.ps1`, which holds no logic of its own. It finds your
installed agentic-board (from Claude Code's `installed_plugins.json`, or a sibling `agentic-board`
folder in a repository checkout) and runs that plugin's hook script, so the behaviour is the one
agentic-board's tests cover.

| Hook | What it does |
|---|---|
| `SessionStart` (startup) | A one-time welcome banner. |
| `SessionStart` (startup, resume) | Removes *empty* orphan folders under the current repo's `.claude/worktrees/`. |
| `SessionStart` (compact) | A one-line notice when a saved `/board` handoff exists. |
| `PreToolUse` (Bash, PowerShell, Edit, Write, NotebookEdit, MultiEdit) | Refuses merge, deploy, publish and delete commands **only** inside a worktree that an autonomous run armed with a brake marker. A POSIX `sh` precheck answers every other call without starting `pwsh`. |
| `UserPromptSubmit` | Tells you when a plugin this session loaded has been updated on disk. |
| `PreCompact` | Appends one line (time, repo, session id, transcript path and size) to `~/.claude/agentic-board/compact-markers.jsonl`. |

Fail direction: every hook except the brake is advisory and exits silently when agentic-board
cannot be found. The brake denies the tool call instead, because it only runs once a brake marker
was found.

It sends nothing and fetches nothing. The brake can post one comment on the run's own issue
through `gh` when it denies a call. Privacy:
[agentic-board PRIVACY.md](https://github.com/CSalcedoDataBI/agentic-board/blob/main/plugins/agentic-board/PRIVACY.md).

## License

MIT. See [LICENSE](LICENSE).
