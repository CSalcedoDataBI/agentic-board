# Privacy policy — agentic-board

*Effective 2026-10-03. Maintainer: CSalcedoDataBI — contacto@csalcedodatabi.com.*

This policy covers the **agentic-board** plugin for Claude Code.

## What the plugin collects

**Nothing reaches the maintainer.** The plugin has no server of its own, no telemetry and no
analytics. It runs PowerShell scripts, `gh` and `git` on your machine, as you. What it writes stays
on your machine or goes to the GitHub repositories and boards you point it at.

## What it reads and sends

| When | What happens | Where it goes |
|---|---|---|
| Any command or skill | Claude reads files from the installed plugin folder and runs its scripts locally | Nowhere: local |
| A GitHub operation (`/board`, `/scan`, `/expert`, `/docs`, …) | `gh` calls with **your** token: read and edit issues, project items and fields, labels, pull requests, comments | GitHub, only the repositories and boards you name |
| Opening a PR, parking a session, publishing the wiki | `git push` of the branch or wiki pages | Your repository's `origin` on GitHub |
| `abios-feedback` skill | Opens a sanitized issue about the tool itself, after you see the exact text and say yes | The public repository `CSalcedoDataBI/agentic-board` |
| `/docs` DeepWiki check | HTTP GET of `https://deepwiki.com/<owner>/<repo>`, only for a public repository | deepwiki.com |
| `/skills bootstrap`, `/tools` install | Fetches one pinned commit of a public skill repository | github.com (read only) |
| Heavy-memory proposal (optional) | Reads package metadata; installs only with explicit flags | pypi.org |
| `/board work -Launch` / `-Fleet` | Starts a coding CLI (`claude`, `codex`, `copilot`, `agy`, `jules`) in a terminal on your machine | Whatever that CLI's own service is, under that CLI's own terms |
| Hooks (`PreCompact`) | Appends one line (time, repo, session id, transcript path and size) | `~/.claude/agentic-board/compact-markers.jsonl`, local |
| `/board telemetry` | Reads your local Claude Code transcripts | Results written locally only |

## Credentials

The plugin reads your GitHub token from an environment variable: `GH_TOKEN`, the stored `gh`
login, or a variable named in your own `~/.agentic-board/accounts.json`. That file stores variable
**names**, never token values. The token is passed to `gh`/`git` for the call and is never written
to disk by the plugin. A session launched by `/board work` gets only its model credential and one
GitHub identity: every other variable whose name contains `TOKEN`, `KEY`, `SECRET` or `PASSWORD`
is removed first.

Your code, issues and conversations stay between you, Claude, GitHub and the tools you already
use. The plugin keeps no copy of them and retains no data of its own.

Maintainer scripts in the repository outside the plugin folder (CI, guards) are **not** run by the
plugin.

## Children

The plugin is a developer tool and is not directed at anyone under 18.

## Changes and contact

Changes to this policy are made in this file and recorded in the repository history.
Questions: contacto@csalcedodatabi.com, or [GitHub issues](https://github.com/CSalcedoDataBI/agentic-board/issues).
