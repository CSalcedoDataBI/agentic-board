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

- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`), `git`, and the [`gh` CLI](https://cli.github.com/).
- A GitHub token with the `repo` and `project` scopes. With one account, `gh auth login` and
  `gh auth refresh --scopes project` are enough: the plugin falls back to `GH_TOKEN`, then
  `gh auth token`. With several accounts, `/board setup` writes `~/.agentic-board/accounts.json`,
  which maps each account to the environment variable holding its token (names only, never values).
- **Platform:** Windows, macOS and Linux. The test suite runs on Windows and on Ubuntu in CI.
  Windows Terminal tabs are Windows-only: elsewhere a launched session runs as a background
  `pwsh` and its output goes to `launch-<n>.console.log`.

## Use

Type `/board` with no arguments for a menu, or ask in plain language ("what's pending?",
"start issue #42", "move these to Done"). Typed commands: `/board`, `/scan`, `/skills`,
`/knowledge`, `/tools`, `/docs`, `/expert`, `/cleanup`. Each one lists its verbs when run
without arguments.

## What this plugin runs, sends and fetches

**Runs on your machine**

- PowerShell scripts from this plugin's `scripts/` folder, plus `gh` and `git`.
- Hooks registered automatically when the plugin is enabled (the two cheap prechecks are POSIX
  `sh` scripts, run by Claude Code with Git Bash on Windows and `sh` elsewhere):
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
- **`dsh` (DeepSeek Harness, pilot)** with `-Fleet` only, and only for Docs/Chore issues of a
  **public** repository (an unknown visibility counts as private). It never runs on your machine
  directly: the session is `docker run --rm` of the local image `agentic-board/dsh:0.2.0-rc.2`,
  with the worktree as its only writable mount, a read-only root, no home folder, no Docker
  socket, a non-root user, CPU/memory limits and one variable from your environment,
  `DEEPSEEK_API_KEY` (no GitHub token: it edits files, it does not push). The launch itself
  re-checks the issue's route and the repository's visibility, and starts claude instead when
  either fails. When dsh finishes, the tab tells you to review `git diff` and to commit and open
  the PR yourself. Details and the image
  recipe: [`containers/dsh`](https://github.com/CSalcedoDataBI/agentic-board/tree/main/containers/dsh).
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
  `npm i -g @openai/codex@0.160.0`, `npm i -g @github/copilot@1.0.91` or `npm i -g @google/jules@0.1.42`
  (pinned versions). Antigravity ships only a remote install script, so it is never run for you: you
  get the install page instead. `dsh` is never installed for you either: you build its image
  yourself (`docker build -t agentic-board/dsh:0.2.0-rc.2 containers/dsh`), from a pinned base image
  and a lockfile, and the fleet never pulls an image.
- `/cleanup plugins` runs `claude plugin marketplace update` and `claude plugin update` for your
  installed plugins.

- **Credentials.** Your GitHub token is read from `GH_TOKEN`, the stored `gh` login, or a variable
  named in your own `~/.agentic-board/accounts.json` (names only, never values). It is passed to
  `gh`/`git` for the call and never written to disk by the plugin.

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
- A `dsh` session sends its task (the issue briefing) and whatever it reads or runs in the worktree
  to DeepSeek's API (`https://api.deepseek.com/anthropic`), under DeepSeek's own terms. dsh's
  extra uploads are switched off in the image: the session-log upload (a copy of the session log
  that dsh 0.2.0-rc.2 adds to every API request by default) and its OpenTelemetry export; the image
  build fails if they are not. Per dsh's documentation its API requests still carry a session id
  and an anonymous user id, which here is random per run (dsh's home folder lives in the
  container's temporary storage and is discarded on exit).
- Nothing else: there is no analytics or telemetry upload. `/board telemetry` reads your local
  Claude Code transcripts and writes its results locally.

**Fetches**

- `/skills bootstrap` and `/tools` install skills by fetching one pinned commit of the public GitHub
  repository listed in the catalog, and keep that repository's LICENSE next to the skill.
- `Suggest-HeavyMemory.ps1` (the optional heavy-memory proposal) reads package metadata from
  `https://pypi.org/pypi/basic-memory/json`. Only with `-Install -AcceptAgpl -Version <x>` does it
  install that exact version of `basic-memory` (AGPL-3.0) through `uv` or `pipx`.

Full privacy policy: [PRIVACY.md](PRIVACY.md).

## License

MIT. See [LICENSE](LICENSE).
