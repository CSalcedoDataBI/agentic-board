# The auto-loop — what the launched autonomous session does

`Expert-Auto.ps1` composes a brief (`Format-AutoBrief`) and launches a dedicated session in an
isolated worktree. That session follows this loop. It is the operational contract behind the
guiding principle: **total self-use of agentic-board — never improvise your own tooling.**

## Phases

1. **Ingest** — read the epic/issue and its enriched plan (Research, Role seed, Deliverables,
   Test plan / DoD). The brief file (`.agentic-board/expert-brief-<issue>.md`) carries all of it.
2. **Become the expert** — adopt the role objective. Research prior-art and docs, and **register
   findings** via `/knowledge add` / `/knowledge harvest` (read-and-forget is not allowed).
   Acquire missing tooling via `/skills bootstrap` / `/skills audit`.
3. **Execute (test-first)** — build guided by tests first, in the worktree.
4. **Verify + evidence** — run the definition-of-done gates. Write a structured `[abios-evidence]`
   block (`Expert-Evidence.Format-EvidenceBlock`) to **three places**: the PR body, a durable
   issue comment, and a versioned `evidence/<issue>.md`. If green → open the PR + run the review
   gate **with `-RequireIndependentReviewer`** (#623) — this run is unsupervised, and that flag is
   what stops it from certifying its own work (#541). Evidence posted under its own identity does
   not count and `-RecordReview` refuses outright; it waits for a review from a genuinely
   different identity (the repo's CI review workflow — `claude-review`/Copilot post as a bot
   account) instead of inventing one. See `independent-reviewer-guard.md` for the full mechanism
   and why `codex-rescue` isn't wired in yet.
5. **Self-heal + auto-drive the board**:
   - in-scope problem → fix it in the loop and continue;
   - out-of-scope finding → file a sanitized `discovered` issue on the board (`/board`, the
     `abios-feedback` sanitization criteria) and keep going.
6. **Loop until done or budget**: keep iterating until the DoD is green — then **leave the PR
   ready and STOP before merge** (the irreversible line) — or the budget is spent →
   `/board handoff -Save` so a later session resumes. The time budget is **enforced
   mechanically** (#564): it travels in the brake marker, and past `maxMinutes` the PreToolUse
   hook refuses further work commands — only the wrap-up (handoff, commit/push WIP, report)
   still passes. A refused command past the budget is the control working, not an obstacle.
7. **Report** — final evidence + updated board + a PR awaiting the human's merge approval.

## The capability map (each need → an agentic-board capability)

| Need | Capability |
|---|---|
| Research / prior-art | `/knowledge add`, `/knowledge harvest` |
| Acquire / verify skills | `/skills bootstrap`, `/skills audit`, `/skills freshness` |
| Discover latent work | `/scan` |
| Record work / findings | `/board` issue, `/board plan`, `/board triage` |
| Report progress / evidence | `/board update`, `/board changelog`, `[abios-evidence]` |
| Survive budget / interruption | `/board handoff -Save` |
| Clean up | `/board doctor`, `/board cerrar-ciclo` |

## The brake (never cross without a human)

`Expert-Autonomy.Test-IsIrreversible` — STOP before: **merge, deploy, refresh, publish, delete**.
Fail-safe: an action the gate does not recognize is treated as irreversible. Reach "PR ready +
gate green" and stop there.
