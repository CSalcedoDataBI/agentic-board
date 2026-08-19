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

## What #623 still has to do

This issue only changed the GATE's verification rule. It does not:
- Pass `-RequireIndependentReviewer` from `Expert-Auto.ps1` / the auto-loop — the autonomous
  launcher has to opt in explicitly for the guard to apply to its own runs.
- Invoke `codex-rescue` (or any reviewer) at all. Today, an autonomous run that is required to
  be independently reviewed and has no independent reviewer available simply cannot pass the
  gate — which is correct (fail closed), but useless without #623 wiring an actual reviewer
  call into the loop before evidence is marked green. See `codex-plugin-spike.md` (#621) for
  what that reviewer call needs to look like (the `codex-rescue` agent, restart-before-use,
  prose not structured output).
- Decide what identity the `codex-rescue` call's own evidence should be posted under so it is
  itself something OTHER than the implementing session's account — a GitHub Action posting as
  `github-actions[bot]` (the same shape `pr-review.yml`/claude-review already uses) satisfies
  `-RequireIndependentReviewer` today with zero further gate changes; a local `codex-rescue`
  subagent call whose result the SAME session then posts via `-RecordReview` would not, because
  the posting account is still the PR author. That distinction is #623's design decision, not
  this one's.
