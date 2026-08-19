# Spike: the official Codex plugin as an independent reviewer (#621)

Part of #620. Findings from installing and probing `openai/codex-plugin-cc` (popular,
actively maintained, Apache-2.0) — evaluated as the independent, cross-vendor reviewer
that could close the self-certification gap tracked in #622.

## What it is

A genuine Claude Code plugin (not a hand-rolled CLI wrapper), installed with:

- `claude plugin marketplace add openai/codex-plugin-cc`
- `claude plugin install codex@openai-codex`

It delegates through the local Codex CLI (the `codex` binary, package name `codex-cli`),
reusing whatever ChatGPT/API auth is already configured — on this machine it was already
installed and logged in via ChatGPT (the same binary the `second-opinion` skill already
shells out to).

## Component inventory (from `claude plugin details codex@openai-codex`)

- **Skills (11):** `adversarial-review`, `review`, `rescue`, `result`, `status`, `cancel`,
  `setup`, `transfer`, plus three internal ones (`codex-cli-runtime`, `codex-result-handling`,
  `gpt-5-4-prompting`).
- **Agent (1):** `codex-rescue` — a real subagent registered in the Agent-tool registry, not
  just a slash command. This is the piece that matters for #622: Claude can invoke it
  proactively, and it runs as GPT/Codex, a genuinely different vendor/identity from the
  Claude session doing the implementing.
- **Hooks (3):** SessionStart / SessionEnd / Stop (harness bookkeeping only, no model cost).
- Always-on cost: ~327 tokens added to every session; each skill/agent invocation pays its
  own on-invoke cost (roughly 400-870 tokens per call).

## Two findings that shape the #622/#623 design

1. **A fresh install needs a session restart before it is callable.** Right after
   `claude plugin install`, invoking any of its skills in the *same* session fails with
   `Unknown skill`. The plugin only becomes callable in a session started after the install.
   Consequence for #623: an autonomous board-expert run cannot bootstrap this reviewer for
   itself mid-run the way it bootstraps skills via `/skills bootstrap` — the plugin must be a
   **precondition of the launch environment** (installed once, ahead of time), not something
   `Expert-Auto.ps1` can install-and-use in the same pass.
2. **Output is prose, not structured data.** `/codex:adversarial-review` returns a readable
   review — questions about tradeoffs, assumptions, failure modes — with no documented
   JSON/schema mode. #622's marker convention (what `Board-ReviewGate.ps1` parses as "a real,
   independent review happened") needs to key off the *fact that the skill/agent ran and
   returned a non-empty verdict*, not off parsing structured fields out of its prose.

## Recommendation for #622

Use `codex-rescue` (the registered agent) as the identity boundary, not `/codex:adversarial-review`
as a slash command a Claude session could just as easily skip. Concretely: the review-gate
condition should require a PR comment or evidence-file entry that only the `codex-rescue`
agent's own tool-call trace could have produced (e.g. a marker the agent is instructed to post
itself, verified against the Codex session id `/codex:result` exposes) — never a marker the
implementing Claude session posts *about* having asked Codex, which is exactly the same
self-certification shape as the #541 hole this plan exists to close.

## Not evaluated in this spike

- Whether `codex-rescue` can run fully headless (no interactive Claude Code session) for a
  launched autonomous worktree session — needs a real end-to-end test in #623.
- Codex usage-limit/quota impact of using it as a mandatory gate on every PR (contribution to
  the account's Codex usage limits was documented but not quantified).
