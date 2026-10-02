# agentic-board

Run coding agents off your real GitHub Projects board. agentic-board is a Claude Code plugin that
reads and updates the GitHub Projects (v2) board and issues you already use, through the `gh` CLI.
It picks the next issue, starts it on its own branch or git worktree, takes it through a pull
request and a review gate, and stops before anything destructive until you confirm.

Full guide, screenshots and roadmap: <https://github.com/CSalcedoDataBI/agentic-board>.

## Install

```
/plugin marketplace add CSalcedoDataBI/agentic-board
/plugin install agentic-board@agentic-board
```

## Requirements

- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`), `git`, and the [`gh` CLI](https://cli.github.com/), authenticated.
- A GitHub token with the `repo` and `project` scopes (classic PAT). The plugin reads it from an
  environment variable (default `GITHUB_TOKEN_PERSONAL`), never from the repository.
- **Platform:** developed and tested on Windows. The scripts are PowerShell 7, but token lookup,
  the terminal-tab launcher and two hooks still use Windows-only calls (`cmd`), and one of those
  two is the `PreToolUse` brake, so on macOS/Linux that brake does not run. Cross-platform support
  is tracked in [#767](https://github.com/CSalcedoDataBI/agentic-board/issues/767).

## Use

Type `/board` with no arguments for a menu, or ask in plain language ("what's pending?",
"start issue #42", "move these to Done"). Typed commands: `/board`, `/scan`, `/skills`,
`/knowledge`, `/tools`, `/docs`, `/expert`, `/cleanup`. Each one lists its verbs when run
without arguments.

## What this plugin runs, sends and fetches

**Runs on your machine**

- PowerShell scripts from this plugin's `scripts/` folder, plus `gh` and `git`.
- Hooks registered automatically when the plugin is enabled:
  - `SessionStart`: a one-time welcome banner, a handoff notice after a compaction, and a sweep that
    removes *empty* orphan folders under the current repo's `.claude/worktrees/`.
  - `PreToolUse` (Bash, PowerShell, Edit, Write, NotebookEdit, MultiEdit): refuses merge, deploy,
    publish and delete commands **only** inside a worktree that an autonomous run armed with a brake
    marker. Everywhere else it allows the call.
  - `UserPromptSubmit`: tells you when a plugin this session loaded has been updated on disk.
  - `PreCompact`: appends one line (time, repo, session id, transcript path and size) to
    `~/.claude/agentic-board/compact-markers.jsonl`.
- With `/board work ... -Launch` or `-Fleet` only: it opens one terminal session per started issue
  and runs a coding CLI in it (`claude`, and with `-Fleet` also `codex`, `copilot`, `agy` or `jules`).
- **Permissions of launched sessions.** By default each launched CLI keeps its own permission mode
  and your allow-list, so a headless session is *denied*, not asked, for any tool outside it. The
  CLIs' bypass flags (`--permission-mode bypassPermissions`, `--dangerously-bypass-approvals-and-sandbox`,
  `--allow-all`, `--dangerously-skip-permissions`) are added **only** when you pass
  `-AllowPermissionBypass`, and the launcher prints a red warning when you do.
- **Secrets in launched sessions.** Before the CLI starts, the launch script removes every
  environment variable whose name contains `TOKEN`, `KEY`, `SECRET` or `PASSWORD`, then restores
  only the CLI's model credential and one GitHub identity as `GH_TOKEN`. Limit: a process running as
  you can still read your own stores (the Windows user environment, a keyring, a dotfile).
- Installs software **only after a y/N prompt**: when `-Fleet` finds a CLI missing it offers
  `npm i -g @openai/codex`, `npm i -g @github/copilot`, `npm i -g @google/jules`, or Antigravity's
  install script (`irm https://antigravity.google/cli/install.ps1 | iex`).
- `/cleanup plugins` runs `claude plugin marketplace update` and `claude plugin update` for your
  installed plugins.

**Sends**

- GitHub API calls through `gh`, as the account whose token you configured: reading and editing
  issues, project items and fields, labels, pull requests and comments in the repositories and
  boards you point it at.
- `git push` to your repository's `origin`: the issue branch when a PR is opened
  (`New-BoardPR.ps1`), unmerged session branches that `/cleanup sessions` parks as draft PRs, and
  the GitHub Wiki when you publish with `/docs wiki`.
- The `abios-feedback` skill can open a sanitized issue about the tool itself on the public
  repository `CSalcedoDataBI/agentic-board`.
- `/docs` checks DeepWiki indexing with an HTTP GET to `https://deepwiki.com/<owner>/<repo>`,
  and only for a public repository.
- Nothing else: there is no analytics or telemetry upload. `/board telemetry` reads your local
  Claude Code transcripts and writes its results locally.

**Fetches**

- `/skills bootstrap` and `/tools` install skills with `git clone --depth 1` from the public GitHub
  repository listed in the catalog, and keep that repository's LICENSE next to the skill.
- `Suggest-HeavyMemory.ps1` (the optional heavy-memory proposal) reads package metadata from
  `https://pypi.org/pypi/basic-memory/json`. Only with `-Install -AcceptAgpl -Version <x>` does it
  install that exact version of `basic-memory` (AGPL-3.0) through `uv` or `pipx`.

## License

MIT. See [LICENSE](LICENSE).
