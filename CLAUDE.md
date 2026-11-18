# agentic-board — notes for agents

- **North:** [`FICHA.md`](FICHA.md) — what this tool is, what it is not, and its protected zones. Read it
  before changing anything.
- **Contributing rules:** [`CONTRIBUTING.md`](CONTRIBUTING.md) — private cause, public contribution;
  command surface; docs regeneration; releasing.
- **Branches:** feature PRs target `next`. `main` is followed by the plugin directory and only receives
  the release PR; `release` is moved by the release workflow; `stable` (what the plugin directory tracks) only by
  `scripts/Build-Stable.ps1` plus a measured, plain push, never forced.
- **Two plugins:** `plugins/agentic-board/` is Markdown only (no scripts, no hooks: the directory refuses
  them); every script, preset and hook goes in `plugins/agentic-board-tools/`.
- **Merging:** the experto (`.claude/agents/experto.md`) reviews each PR against `FICHA.md` and merges it
  into `next` when CI is green and the review is clean.
- **Tests:** `Invoke-Pester -Path tests/agentic-board`.
- Code, commits and board content in English, Conventional Commits.
