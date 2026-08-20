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

## Headless invocability — verified (#637, 2026-08-20)

Confirmed with a real `claude -p` launch (no interactive session), after renewing the OAuth
token used for headless auth:

- **The earlier "Agent type 'codex-rescue' not found" result (#623) was a naming bug in that
  investigation, not an infrastructure limitation.** The Agent tool requires the fully-qualified
  `namespace:name` form. `subagent_type: 'codex-rescue'` (unqualified) is rejected;
  `subagent_type: 'codex:codex-rescue'` (qualified) launches successfully, headless, with no
  interactive session involved.
- Once launched, the subagent's own Bash tool ran real commands (`codex --version`, and a real
  one-paragraph adversarial review of this repo's README) and returned genuine output — this is
  the actual Codex CLI, authenticated, not a stub.
- One transient EPERM (`lstat` on the user's home directory) was observed on a single Bash call
  inside the subagent and did not reproduce on retry — noted as a possible flake, not treated as
  a blocker since three subsequent invocations succeeded cleanly.
- A genuine invocation produces machine-checkable identifiers that only a real Codex CLI call
  writes: `CODEX_COMPANION_SESSION_ID`, `CODEX_THREAD_ID`, and — most useful as a marker — a
  **rollout file** on disk at `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<thread-id>.jsonl`.
  That file is written by the Codex CLI process itself; a Claude session cannot fabricate one
  without actually invoking Codex. See `independent-reviewer-guard.md` for the marker design this
  enables.

## Not evaluated in this spike

- Codex usage-limit/quota impact of using it as a mandatory gate on every PR (contribution to
  the account's Codex usage limits was documented but not quantified).
