# The independent-reviewer guard (#541/#622)

What `Board-ReviewGate.ps1 -RequireIndependentReviewer` does, and what it deliberately does
NOT do — read this before wiring it into the auto-loop (#623).

## The hole this closes

`Get-ReviewEvidence` (the function that decides "was this diff actually reviewed?") used to
trust evidence purely by TEXT: any GitHub review, or any PR comment containing
`[abios-review] <who> sha=<head>`, counted — regardless of who posted it. The account that
opened a PR could post its own `[abios-review] codex/gpt-5.5 sha=...` comment and the gate
would read it exactly like a genuine independent review. That is the shape of #541: an
autonomous board-expert run certifying its own work.

## The fix, and why it is opt-in

`Get-ReviewEvidence` now takes an optional `-PrAuthorLogin`. When set, evidence (a GitHub
review OR an `[abios-review]` comment) authored by that SAME login does not count, however
convincing its text. `Board-ReviewGate.ps1` only computes and passes it when the caller passes
`-RequireIndependentReviewer` — **off by default**.

It has to be opt-in. The gate's main fallback path — a human runs `/board work`, Copilot/
claude-review are unavailable, they genuinely read the diff (or ran `second-opinion`) and
record it with `-RecordReview` — posts that record under their OWN account, which on a solo
repo is also the account that opened the PR. That is supervised and legitimate; a blanket
"PR author excluded" rule would have broken the gate's primary fallback for the exact
reviewer-scarce situations it exists for. `-RequireIndependentReviewer` scopes the stricter
rule to callers that KNOW they are an unsupervised context — board-expert's autonomous
launcher, not the interactive human flow.

`-RecordReview` also fails LOUD under `-RequireIndependentReviewer`: if the active identity
(`gh api user`) matches the PR author, it throws immediately with a pointer to #541, instead
of silently posting a comment that later evidence-checking would just ignore.

## What #623 did (and what it deliberately did NOT do)

#623 wired `Expert-Auto.ps1`'s brief (`Format-AutoBrief`) to instruct every autonomous run to
call the gate with `-RequireIndependentReviewer`, to refuse self-recording, and to wait for a
CI-bot review (`claude-review`/Copilot — already a distinct identity from the run, satisfies the
guard with zero further gate changes) instead of inventing its own review. `auto-loop.md` phase 4
carries the same instruction for anyone reading the skill directly.

It did **not** wire `codex-rescue` as the reviewer, despite that being the epic's (#620) original
intent. Two attempts to verify it before designing around it both failed, and the failure was
infrastructure, not a design dead-end:
- `codex-rescue` is not invokable via an Agent-tool call from this harness (tried, got "Agent
  type not found" even though `claude plugin list` shows the plugin installed and enabled) — the
  same is true of `/codex:adversarial-review` via the Skill tool ("Unknown skill").
- A real headless test — spawning `claude -p` the same way `Expert-Auto.ps1`'s launcher does —
  could not run at all: `401 OAuth access token has been revoked`. That is an environment/
  credential problem, unrelated to whether the plugin itself would work headless.

Given both paths were blocked and the epic's own spike (`codex-plugin-spike.md`) already flagged
"whether `codex-rescue` can run fully headless... needs a real end-to-end test" as unevaluated,
wiring a specific, unverified call into every autonomous run's mandatory gate would have made the
gate untestable and potentially unshippable (every run failing on a reviewer nobody can reach).
The human owner chose the CI-bot fallback explicitly over guessing at the wiring or blocking on an
unrelated OAuth fix.

## Update (#637, 2026-08-20): headless invocability confirmed

Both blockers above are resolved:

- The OAuth token was renewed (`claude setup-token`), so headless `claude -p` auth no longer
  fails with `401 OAuth access token has been revoked`.
- **The "Agent type not found" result was a naming bug, not an infrastructure limitation.**
  `subagent_type: 'codex-rescue'` (unqualified) is rejected by the harness; the fully-qualified
  `subagent_type: 'codex:codex-rescue'` launches correctly, headless, and ran a real Codex CLI
  review (see `codex-plugin-spike.md` for the verification detail).

### Marker design (the open question #622/#623 deferred)

A genuine `codex:codex-rescue` invocation produces a **rollout file** the Codex CLI writes to
`~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<timestamp>-<thread-id>.jsonl`, plus a
`CODEX_THREAD_ID`. This is the marker the spike recommended: something only the agent's own
tool-call trace could produce, not a claim the implementing Claude session could post about
having asked Codex. A trustworthy gate check would be: the PR evidence cites a rollout path +
thread ID, `Board-ReviewGate.ps1` verifies the file exists and its filename's thread-id segment
matches the cited one (and, ideally, that the file's mtime is at/after the PR's head commit
time) — a claim with no matching file, or a stale one, does not count.

## What #644 wired (opt-in, alongside the CI-bot fallback — not replacing it)

The repo owner's call on the open question above: land the marker as something a run can
*choose*, not something every autonomous PR is forced to pay Codex quota for, since that cost was
never quantified.

- `Board-ReviewGate.ps1 -RecordReview -RolloutPath <path> -ThreadId <id> ...` embeds the marker
  (`rollout="..." thread=...`) in the `[abios-review]` comment — and refuses to post it if the
  file does not exist or the thread id does not match the filename (fail fast, never record a
  claim that cannot later be checked).
- `-PreferCodexRescue` (new gate switch) re-verifies any rollout/thread marker against disk at
  gate time. A marker that does not verify is dropped from evidence as though it were never
  posted — so a fabricated session cannot earn credit, and if it was the only evidence the gate
  correctly reports unreviewed rather than trusting the text. Plain `-RecordReview` comments
  (no marker) and GitHub reviews (Copilot/claude-review) are untouched by this — the flag only
  tightens the codex-rescue path, and only when passed.
- `Expert-Auto.ps1`'s brief documents this as an optional path for a run that chooses it; the
  CI-bot fallback (`-RequireIndependentReviewer` alone) stays the default for everyone else.

Genuinely still open: whether to ever make this the *default* rather than opt-in, and the real
Codex/ChatGPT usage-limit cost of doing so — left unmeasured on purpose, revisit once there is
usage data from runs that opted in.
