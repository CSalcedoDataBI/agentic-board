# Compaction-survival for long /board work runs

A single-session `/board work` run that works a queue of issues X→Z fills the context
window and eventually **auto-compacts**. Claude Code's generic summary drops the thread —
which issues are done, which are pending, the key decisions — and the unattended run loses
its way. This feature re-grounds the session automatically after any compaction, so the
queue keeps moving without a human typing `/compact`.

## Three things Claude Code cannot do (so we don't rely on them)

Verified 2026-07-17:

- **No programmatic `/compact`.** Slash commands are not callable from hooks.
- **No instructions for auto-compact.** `/compact <text>` works manually, but the `auto`
  trigger receives an empty `custom_instructions`
  ([anthropics/claude-code#14160](https://github.com/anthropics/claude-code/issues/14160)).
- **No cheap model for compaction.** Compaction uses the session model; there is no setting.

The reliable lever is the **`SessionStart` hook with `source: "compact"`**, which fires
*after* compaction and can inject `additionalContext`. So we don't shape the summary — we
make it irrelevant by re-injecting ground truth.

## Persistence model (mirrors /board handoff)

Two places, like the handoff:

| Where | What | Who reads it |
| --- | --- | --- |
| **Durable:** an upserted `<!-- abios-run-ledger -->` comment on the **epic** issue | queue header + a one-row-per-update table of decisions / next-steps (what the board does *not* hold) | the reawakened agent, in-session, via `gh` |
| **Local breadcrumb:** `.agentic-board/active-run.json` (`{epic, board, repo, status, ...}`) | a lockfile-sized marker | the **offline** `SessionStart(compact)` hook |

The board itself remains the always-fresh per-issue **status** — re-read via `gh`, never
mirrored. The ledger only carries what the board cannot.

## The hook contract

`Handoff-SessionStartHook.ps1` (matcher `compact` in `hooks/hooks.json`):

- Reads **only** the local `active-run.json` marker — **never** the network (a SessionStart
  hook runs on every session and must stay fast).
- If a run is `active`, emits a **pointer**: "you auto-compacted mid-run of epic #N; re-read
  the `[abios-run-ledger]` comment with `gh issue view N --comments`, and re-read each
  issue's live status from the board before resuming."
- **Strict no-op** when there is no marker or the run is `closed` — so it is safe shipped
  always-on for every session, not just board runs.
- Read-only, offline, never blocks, never throws, always exits 0 (same guarantees as the
  `resume` path it sits beside).

`Compact-PreCompactHook.ps1` (matcher `*` under `PreCompact`) is a **safety net**: before a
compaction it appends one line to `<ClaudeHome>/agentic-board/compact-markers.jsonl`, with when,
the trigger, the repo, the session id, and the transcript path and size. That is enough to go back
to the raw transcript if the ledger has a gap. Claude Code keeps that transcript in
`~/.claude/projects`, and compaction appends to it rather than truncating it. It **never blocks**
(blocking risks hitting the hard context limit mid-issue) and always exits 0.

Before #737 the hook copied the whole transcript into `<repo>/.agentic-board/compact-snapshots/`.
That was a verbatim duplicate (1.7 GB on one machine), and it carried the entire context window,
global CLAUDE.md included, into a repo folder. Nothing is written inside the repo any more. Old
copies are removed by `/cleanup disk` only when the original transcript still holds them.

## Maintaining the ledger — `Board-RunLedger.ps1`

The `/board work` loop keeps the ledger current at three touch-points:

```powershell
# When you begin working a queue tied to an epic:
Board-RunLedger.ps1 -Start  -Epic <n> [-Board <b>] [-Queue <n,...>]

# After each issue closes (its PR merged), record what the board doesn't hold:
Board-RunLedger.ps1 -Update -Epic <n> -Issue <i> -Note "<decision/gotcha>" -Next "<next step>"

# When the whole queue is done:
Board-RunLedger.ps1 -Close  -Epic <n>
```

Keep entries lightweight — a decision, a gotcha, the next step — not a transcript. The
comment upsert is **fail-closed** (a failed read of existing comments skips the post rather
than risk a duplicate, per #316); a gh failure never corrupts the local marker.

## Enable / disable

The `compact` re-injection and the PreCompact marker ship enabled in the plugin
`hooks/hooks.json`. Both are strict no-ops outside an active run, so there is nothing to
disable for normal sessions. To turn them off entirely, remove the `compact` `SessionStart`
entry and the `PreCompact` entry from `hooks/hooks.json`.

The `resume`-source handoff surfacing remains **opt-in** via your own `settings.json` (see
[handoff-hook.md](handoff-hook.md)) — this feature does not change that.
