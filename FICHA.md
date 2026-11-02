# Ficha — agentic-board

> The ficha is this tool's charter. Its experto (`.claude/agents/experto.md`, the agent that reviews and
> merges PRs) reads it on every PR. Maintained with the maintainer's internal rules.
> **The parent** (the portfolio agent that directs the maintainer's tool repos) approves it in the
> `Approved:` line: the date first, then an optional parenthesis with who approved. Changing the ficha
> requires a new approval. **The maintainer** is Cristóbal, the human owner: only the maintainer gives the
> OK to publish.

## What it is

- **What it builds and for whom:** a Claude Code plugin that runs coding agents off a real GitHub
  Projects (v2) board — pick an issue, branch, build, review gate, PR and board moves — for anyone who
  tracks work on a GitHub board. Also ships the `/skills`, `/knowledge`, `/scan`, `/expert`, `/cleanup`
  and `/docs` modules.
- **Role:** tool.
- **Public/private twin:** none.

## North

- **Current plan:** the issues on this repo's board ([Projects](https://github.com/CSalcedoDataBI/agentic-board/projects)).
  No epic is open today; each PR answers its issue.
- **Product agenda:** user-facing first, self-governance second (`CONTRIBUTING.md`, «Product agenda»).
- **What this tool is NOT:**
  - not a place for anything from a private project: the cause may be private, the contribution is
    public-only (no repo names, client data, GUIDs, tokens or local paths);
  - not an editor of other tools' repos: it installs rulesets, templates and CI into a user's repos
    only when the user runs it there;
  - not a publisher: merging is not publishing to the plugin directory.

## Protected zones

What is not touched without a plan step that names it:

- `main` and `plugins/agentic-board/` on `main` — the plugin directory follows `main` and has a version
  under review; every commit there replaces it. Feature PRs target `next`; `main` only receives the
  release PR, and only under the directory protocol with the maintainer's OK.
- `stable` and `release` branches and the `ref` in `.claude-plugin/marketplace.json` — they are what
  installs fetch; they move only through the release workflow.
- Internal state keys: the `.agentic-board/` state dir, `~/.agentic-board/backups`, the `ABIOS_*`
  environment variables and the `Get-AbiosStateDir` helper — on-disk identifiers on users' machines;
  renaming them orphans live sessions.
- The command surface: typed command names (`/agentic-board:<noun>`) and their verbs — users type
  them; renames go through the rules in `CONTRIBUTING.md` («Command surface»).
- Generated regions of `README.md` (`<!-- BEGIN:... -->` markers) — edited only through
  `Update-Docs.ps1`.
- The private-data guard: `scripts/install-guard.ps1` and its hooks — the layer that keeps private
  data out of a public repo.

## Layer and feedback

- **Node layer:** none.
- **Feedback skill:** `agentic-board:abios-feedback`.

## Check and experto

- **Required CI check:** `Pester` (ruleset `pr-before-merge (agentic-bi-ops)` on `main`). The same CI
  (`Pester`, `docs`, `validate`) runs on PRs to `next`.
- **Test suite:** `Invoke-Pester -Path tests/agentic-board`.
- **Runner:** GitHub (public repo).
- **Tag format:** `vX.Y.Z` (cut by `.github/workflows/release.yml` when `plugin.json`'s version changes on
  `main`). Pending: move the version decision to release-please.
- **Experto:** `.claude/agents/experto.md`. It merges PRs into `next` as the GitHub App
  `csalcedo-agents[bot]`, with a 1-hour installation token.
- **Directory plugin?:** yes — `stable` is not touched, and nothing merges into `main` while a version is
  under review; publishing follows the directory protocol with the maintainer's OK.
- **Visible parts Cristóbal approves:** none (the directory listing is publishing).

## Approval

Approved: 2026-11-01 (parent, by delegation, after review round 1)
