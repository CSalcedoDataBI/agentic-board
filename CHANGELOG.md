# Changelog

## [Unreleased]
### Changed
- **The autonomous brief now carries the seven-phase loop and the decision protocol, not a
  capability list** (#527, part of #526). `Format-AutoBrief` used to emit a bullet list of
  agentic-board capabilities; the 7-phase method lived in `auto-loop.md`, a file the launched
  session was never handed. The session had no phases, no sequence, and no instruction to
  research before deciding — only "an in-scope problem: fix it in the loop and continue" as its
  sole heuristic.

  The brief now includes the full phase sequence (Ingest → Become the expert → Execute →
  Verify + evidence → Self-heal → Loop until done → Report) and an explicit **decision protocol**:
  when you hit an error, an unexpected state, or a fork in the path, *research before deciding —
  do NOT act first*. Steps in order: Research (check prior-art, register via `/knowledge`),
  Register (log findings — read-and-forget is not research), Decide (then choose the path).
  The capability map is retained as a lookup table inside the same section, subordinate to the
  phases rather than their replacement.

  Verified by five tests that assert on the rendered brief text, not on the source documents: the
  seven numbered phases are present, "research before deciding" appears explicitly, the
  Research-Register-Decide ordering holds inside the protocol section, "read-and-forget" is called
  out, and the no-improvise guard survives. Each was confirmed by reintroducing the defect and
  watching the matching test go red.

  **Caught by external review before merging, and worth recording.** The rewrite replaced the old
  heading `total self-use of agentic-board (do NOT improvise your own tooling)` and never restated
  it. Since this function composes the *only* text the launched session ever receives, deleting that
  line deleted the instruction — a capability map lists options, it does not forbid inventing one.
  The plan's own founding principle, dropped by the change meant to strengthen it. The guard is back
  in the section heading and is now asserted.

  Review also found the ordering test measuring the *first* occurrence of Research / Register /
  Decide across the whole brief. "Research" already appears in phase 2, so the test could stay green
  with the protocol steps scrambled — a test that reported a guarantee it did not hold. It is now
  scoped to the decision-protocol section, and the phase test matches the numbered markers rather
  than bare words ("verify" and "report" also occur in the capability map, so the loose match
  survived deleting the phases).

- **Phase 5 self-heal now explicitly invokes the decision protocol, replacing fix-it-and-continue**
  (#528, part of #526). After #527 added the decision protocol to the brief, Phase 5 still said
  "fix it (after researching first)" — a parenthetical that reads as act-first with a research note,
  not as research-first with an act-later decision. Phase 5 now reads: "when you hit an error, a
  fork, or an unexpected state — apply the **decision protocol** (research → register → decide); do
  NOT act first." The protocol section below it (Research → Register → Decide) is now the named
  authority that self-heal defers to, rather than a separate section that contradicts the phase's
  framing. Verified by three tests scoped to Phase 5 text: decision protocol named in phase,
  "do NOT act first" present in phase, and the old "fix it (after" parenthetical is absent.

## [0.31.0] - 2026-08-03
### Added
- **A braked run can now authenticate as a machine account instead of as the owner** (#550, part of
  #541). The autonomy brake could never be complete as a text classifier — eleven of the nineteen
  defects found on 2026-07-31 were that same defect in different clothes. The capability side is
  different in kind, and it is now wired.

  `main` requires a pull request, but the ruleset **exempts the repository admin role**, and a PAT
  authenticates *as its owner* — so any token of his walks straight through. Weaker permissions do
  not help: GitHub cannot distinguish "the human typed this" from "an agent used the human's token",
  because they are the same principal. Only a **different identity** gets a different answer.

  Measured, not argued, against the new machine account:

  | Action | Result |
  |---|---|
  | write to `main` | `Repository rule violations found — Changes must be made through a pull request (422)` |
  | create an ordinary branch | 200 OK |

  Refused exactly where it matters, still able to do the work. New: one resolver answering *which
  identity applies here*, **wired into `New-BoardPR`** — the script a braked run actually pushes
  through — with `Board-Merge` and `Publish-DocsWiki` now sharing its owner→variable map instead of
  each carrying a copy. `gh-account` teaches the same rule inline, because a run's own `git push`
  never goes through a plugin script; that snippet stays path-independent by design and does not
  call the resolver.

  **Caught by review before merging, and worth recording:** the first cut added the resolver, claimed
  the consolidation, and wired it to *nothing* — referenced only by its own test while four scripts
  kept their duplicate maps. A fifth copy of the rule, shipped as a fix for having copies. That is
  this tool's founding defect (reporting intent as fact) committed inside the change meant to cure
  it. Four tests now assert the claim rather than assert it in prose: the resolver is referenced by
  real scripts, the push path uses it, no duplicated owner map survives, and every consumer loads it
  behind its dot-source guard.

  **Inside an armed run there is no route back to the owner identity — including `-TokenVar`.**
  Review round 2 found the first cut branching on an explicit `-TokenVar` and skipping the armed
  check on that branch, under the comment *"explicit override wins"*: a bypass written as a feature,
  and one flag was enough to undo the whole change. The branch is gone rather than guarded — an
  override is now something the resolver **judges**, not something that routes around it — with a
  structural test forbidding the push script from branching on `-TokenVar` again. Outside an armed
  run an override behaves exactly as before; that is how cross-account work happens.

  **A missing agent token inside an armed run FAILS; it does not fall back to the owner's PAT.** A
  silent fallback would hand the run precisely the capability the brake exists to remove while every
  message still read "brake armed" — the defect this repo has now found in the brake (#440), the
  review gate (#510) and the evidence blocks (#479). Mutation-verified: introducing that fallback
  turns 4 tests red.

  **Stated limit, deliberately not dressed up.** This removes the default capability, not the
  possibility. A run that ignores the skill and reads `GITHUB_TOKEN_PERSONAL` from the registry
  itself is not stopped — the token is ambient in the Windows user environment and cannot be taken
  away from a process running as that user. The deliberate case is what #517 and the review gate are
  for. Treating a backstop as a sandbox is what produced most of yesterday's defects.

## [0.30.0] - 2026-07-31
### Fixed
- **A braked run could push straight to the default branch** (#542). The brake watched `gh pr merge`,
  the REST merge endpoints and `Board-Merge.ps1` — and missed the simplest route of all:
  `git push origin HEAD:main` puts work on main with one command and matched nothing. Present in
  every version of the brake, including shipped 0.29.0, and found only when an external review was
  pointed at *whether the door was really shut* rather than at the change in front of it.

  Not quite an oversight, which is the interesting part: the delete pattern carried a comment
  calling `HEAD:main` "an ordinary push refspec", written while guarding against *over*-matching.
  A test pinned that reading in place. Both were correct about the delete pattern and wrong about
  the vocabulary — this guard defines merge as *"putting work on the default branch"*, which is
  exactly what that refspec does. **The obsolete assertion was corrected, not worked around.**

  Now refused: refspecs onto `main`/`master` (`HEAD:main`, `branch:main`, `+HEAD:main`,
  `HEAD:refs/heads/main`) and pushing the default branch by name.

  **How the branch name must end took three tries, each one a real defect — and the CI reviewer
  caught both mistakes**, in the first two reviews it managed to publish after #543 raised its turn
  cap. `\b` refused `HEAD:main-cleanup` and `HEAD:master.bak`: legitimate branches, blocked, on the
  run's most common command. Replacing it with `(\s|$)` fixed that and **reopened a different
  hole** — that only accepts a space or end-of-segment, and the segment splitter does not treat a
  lone `&` or a redirection as a separator, so `git push origin HEAD:main&` (background the push,
  same effect) matched nothing, a case the original `\b` had caught. It now ends at a lookahead
  over the shell's own terminator set, which covers both directions.

  **A third review round found the anchor itself was wrong — and had always been.** Every git
  rule in this file began `\bgit\s+push\b`, which demands that `push` follow `git`
  immediately. One ordinary global flag shook all of them off at once: `git -C . push origin
  HEAD:main`, `git -c k=v push …`, `git --no-pager push …`. That was never about the new patterns —
  the **pre-existing branch-delete rules had the same hole**, and `git -C . push origin --delete f`
  went through untouched. All four git rules now share one prefix that tolerates flag-shaped tokens
  between the program and the subcommand, so fixing it once fixed the older rules too. Only
  flag-shaped tokens are allowed in that gap, so `git commit -m "push to main"` is still not read
  as a push, and the repetition is bounded rather than `*` — this runs on every tool call, and an
  unbounded nested quantifier over adversarial input is a stall waiting to happen (measured: 1 ms
  against a command carrying 200 flag-like tokens).

  **Round four found two more in that fix — and measuring the repair found a third nobody had
  seen.** The flag allowance was capped at five, which was itself a bypass: six `-c` flags and the
  rule stopped matching, and chaining `-c` is ordinary scripting. And `[:/]` treated `/` as a
  refspec separator, which it is not — `release/master`, `team/main` and `HEAD:team/main` were all
  refused for merely *ending* in the default branch's name.

  Removing the cap came with an argument, made by the reviewer and accepted by me, that the
  repetition could not blow up because its character classes are disjoint. **The argument was
  wrong and only the stopwatch said so:** `--flag` repeated 1000 times ran the matcher past three
  minutes, because `-{1,2}` and `[^\s;|&]+` can both consume the second dash — two readings per
  token, 2^1000 for a thousand of them. This code runs on *every tool call*, so that is not a slow
  path, it is a wedged session, and a wedged guard is a removed guard. The form now allows exactly
  one reading per token: measured at 3 ms with no match and 334 ms in the absurd worst case, with
  three timing tests to catch a return — the suite was green with the hang present.

  Recorded in the source, because this file keeps teaching it: *"the classes are disjoint so it
  cannot blow up" is an argument, not a measurement. Time it.*

  **Round five found no bypass at all** — the first round on this change that did not. Its one
  finding was about honesty rather than permission: `git push origin :main` *deletes* the remote
  default branch, but the merge rule matched it first (its source side allowed zero characters),
  so the refusal announced "merge is marked irreversible" for a command that removes main. Not a
  bypass — the contract filter runs per pattern, so a delete-braking contract already refused it —
  but a control is worth exactly as much as the account it gives of itself, which is this tool's
  founding defect. The refspec source now requires at least one character, so an empty source falls
  through to the delete rule where it belongs.

  Recorded as a decision rather than left to chance: a contract that brakes merges but **not**
  deletes no longer stops that command. It is a delete, and the guard follows the contract instead
  of inventing policy — the rule this file opens with. There is a test saying so.

  **Round six, also no bypass**, and the last one taken: the prefix before the refspec excluded
  only `;`, so the matcher could step past a background `&` and read a later `something:main` in
  the same segment as the push target — `git push origin fine & echo notes:main` was refused for
  text belonging to a different command. A false positive, never a bypass (a looser prefix can only
  add matches), fixed because over-blocking on the run's most common command is the argument this
  whole entry rests on. The prefix now stops at the same operators the branch-name lookahead uses.
  The review's second example, `> log:main.txt`, did not reproduce — checked rather than assumed.

  **Stopped here deliberately.** Rounds one to four found real defects — a bypass, a false
  positive, an anchor broken for months, and a matcher that could hang the session. Rounds five and
  six found no bypass at all: a mislabelled verb and this over-block. The curve flattened, so the
  loop was ended on judgement rather than run until it produced nothing.

  **Known and accepted:** `git push main` is read as a push to the default branch even when `main`
  is the name of a *remote*. A false positive, not a bypass, on a rare spelling — and this pattern
  deliberately errs toward refusing.

  The original over-block, for the record: the tests missed it because the case they checked,
  `maintenance`, continues with `t` (a word character) and so passed **for the wrong reason** —
  proving nothing about `-` or `.`. A green test that passes by accident is the same failure this
  whole entry is about. The reviewer also noted
  that `HEAD:refs/heads/main` was claimed in the description and the code comment but asserted
  nowhere; it has a test now. Deliberately still allowed, since
  this pattern sits on the run's most common command and over-blocking is how a control gets
  switched off: `git push -u origin <branch>`, a bare `git push`, `--force-with-lease` on its own
  branch, and any branch whose *name* merely contains `main` (`issue-9-domain-model`,
  `feature/maintenance`, `HEAD:my-domain`). **Stated limit:** the pure core cannot ask the repo what
  its default branch is, so a project whose default is neither `main` nor `master` is not covered.

- **The reviewer's turn cap sat one turn above what a real review needs** (#543). Measured across
  recent runs: reviews that actually published consumed 4 / 13 / 17 / 18 / **19** turns against a
  cap of **20**, and three consecutive runs on a large PR died at 21. A run that hits the cap leaves
  no review, so the verification added in #510 fails the check — correctly — and the review gate
  ends up blocking legitimate PRs on an infrastructure limit. That is how a control gets switched
  off: not by argument, but by being wrong often enough. Raised to 40, a little over twice the
  observed maximum; time was never the constraint (those runs finish in 2-4 minutes against a
  20-minute job timeout).
- **`-EndToEnd` shipped inert in 0.29.0, and after five review findings it is staying inert — on
  purpose** (#536, #541). Field-testing the autonomy boundary found the ordered end-to-end close
  could refuse but never allow. Three separate blockers were fixed; then three rounds of external
  review found five live false-permission paths in the mechanism that would have opened it, two of
  them complete bypasses. **The boundary held throughout — nothing merged that should not — and
  every failure failed safe.** The order is now recorded, explained, and acted on nowhere.

  What was genuinely broken and is now fixed:

  1. **The tests condition could never be satisfied.** `Invoke-BrakeMergeCheck` dot-sources
     `Board-ReviewGate.ps1`, whose `param()` block runs **in the caller's scope** and declares
     `[int]$PR = 0`. `$PR` silently became `0` immediately before `gh pr checks $PR`, which exits 1
     with empty output, so the CI condition was *always* false. Proven against a real PR whose four
     checks all passed: the gate refused for "missing test evidence"; the same inputs without the
     clobber were permitted. **Stated precisely:** the bug is gone because the code that had it was
     withdrawn with the allowance, not because a line was patched around it. What remains is the
     trap, recorded where the gate will be rebuilt and guarded by a test that proves the review
     gate really does clobber a caller's `$PR` — so #541 cannot walk into it again.
  2. **The tests requirement ignored the contract**, being hardcoded `$true`; and reading it cast
     the string `"false"` to `$true`, the trap already closed for the marker's `endToEnd`.
  3. **The brief never mentioned the order**, so a session carrying one was briefed exactly like a
     session without one. It now says the order was given, that it cannot yet be acted on, and that
     a refused merge is the control working — not a failure to route around. Without that, a run
     reads its own refusal as an error and hunts for another way.

  **Why the ordered close stays shut.** Opening it — even only for the gate's own script, which
  re-checks four conditions and refuses on its own — made two latent holes *reachable*, and neither
  is a string-matching bug (#541):

  | Bypass | Why the gate could not defend itself |
  |---|---|
  | `cd C:\ ; pwsh <genuine-gate> -PR 42` | The hook judges per segment and allows it; the gate then resolves its marker from its **runtime** cwd, finds none outside the worktree, and skips all four conditions. The two halves of the control disagreed about which directory the run was in, and the run picked |
  | `[abios-review] … sha=<head>` | The review condition is a PR comment the run is able to post itself — the self-certification the design had already removed for the *test* condition |

  Three earlier findings were fixed before these: the gated path matched a bare **filename** (any
  file so named passed), then a canonical **path pattern** — which was itself wrong, since the
  installed plugin lives at `<version>/scripts/`, so it would have refused the *genuine* gate in
  every project except this repo — then a **substring** test that a mention-as-argument satisfied,
  then a token match that a `<gate>-bypass.ps1` prefix satisfied while breaking any install under
  `C:\Program Files`. Also fixed on the way: a failed `gh pr checks` read being laundered into
  "this project has no CI", and `dod.tests: false` waiving **red** CI rather than just the
  requirement to have a suite.

  The pattern is the finding: **every round's tests passed, and the next round still found a live
  false-permission path.** That is the argument for keeping the door shut until #541 gives the gate
  a trustworthy armed context and evidence the subject cannot mint.

### Added
- **The brake hook is under test at last** — the piece Claude Code actually executes, and the only
  one that can produce a refusal, had no tests. 17 now drive the real script over real stdin and
  pin both fail directions: silence outside an armed run, denial for anything unclear inside one
  (corrupt marker, emptied list, the string `"true"` posing as an order), plus the `cd`-out shape
  that motivated closing the ordered path.
- Structural regression guards (AST) asserting the merge check never reads a name a dot-source
  destroys, and that the tests requirement is passed rather than assumed.
- An adversarial sweep of 27 evasion classes — command substitution, backticks, env-var prefixes,
  redirections, line continuations, quote-splitting, `bash -c` wrapping, per-segment vouching —
  its catalogue taken from `liberzon/claude-hooks` (MIT, registered in `knowledge/`), which solves
  the same sub-command decomposition problem. Ideas, not code.

## [0.29.0] - 2026-07-30
### Added
- **`/board expert auto -EndToEnd` — an autonomous run can now finish what it started, under four
  conditions** (#530, part of #526). The brake stops being all-or-nothing: a run the owner *ordered*
  to finish may close **code** work that carries a real review and recorded tests for the current
  commit. Everything else still stops for him.

  The four conditions, all established at **merge time** — the first moment the facts exist, since
  the brake marker is written before a line of code is:

  | Condition | Why it cannot be dropped |
  |---|---|
  | The owner ordered it | The permission travels with the instruction, not with a setting written weeks ago |
  | The change is code-class (#529) | What he judges by *looking* at it stays his, even when he ordered the finish |
  | A real review exists for this commit (#510) | A green check is not a review |
  | Automated tests ran and left evidence | "Testable and untested" is not finished work |

  **Why four rather than a priority order.** Each covers a failure the others cannot see: a
  reviewed, tested change that is a dashboard is still his to approve; an ordered, reviewed,
  code-class change nobody ran is still unverified. Collapsing them into one flag is exactly how a
  control ends up meaning less than it says — the defect already found in the brake (#440), the
  review gate (#510) and the evidence blocks (#479). A refusal names **every** unmet condition, not
  the first: one reason at a time forces a round trip per condition and misrepresents how far the
  work actually is.

  The tests requirement reads from the contract's `dod.tests`, **never** from the run's own opinion
  that its change was untestable — a per-run "no se podía probar" is precisely the self-issued
  excuse this removes. A project with genuinely no automated tests says so once, in writing.

  Failing to *establish* the facts is not a yes: if the class, the review or the evidence cannot be
  read, the merge is refused with that as the stated reason.

  Found by its own tests while building: the decision function dot-sourced the classifier without
  its guard, so **every call** also ran a `git diff` and printed a banner — a decision function with
  a side effect per call, running git while deciding whether a merge is allowed.

  19 decision tests + 5 marker tests, mutation-verified: removing the order condition turns 3 red,
  the work-class condition 6, the review condition 4, and the tests condition 5.

- **The autonomy boundary can finally express the owner's actual rule** (#529, part of #526).
  Until now `autonomy.irreversible` was a flat list of *actions* — the same for every kind of work —
  so "code the agent closes by itself; anything I can judge by looking at it waits for me" had
  nowhere to live. The boundary is now about **what the change produces**, not which action performs
  it: a new `workClass` policy in the contract plus a pure classifier that reads the touched paths.

  Why this framing rather than a stricter action list: asking someone who does not read code to
  approve a diff is not caution, it hands them a decision they have no way to make. Asking them to
  approve a **dashboard** is the opposite — they are the only one who can look at it and say whether
  it reads right. So reports, pages, themes and images route to the human; scripts, tests, workflows
  and prose stay with the agent.

  Three decisions worth stating, because each is load-bearing:
  - **Timing.** The brake marker is written at *launch*, before a line exists, so the class cannot
    be decided there. The contract carries the *policy*; the *classification* runs later against the
    paths the run actually touched. Facts first, decision second.
  - **One visual file makes the whole change visual.** The failures are wildly asymmetric — the
    owner glancing at something routine costs a minute; an agent shipping a report he wanted to see
    costs trust.
  - **"I could not tell what changed" is `unknown`, never `code`,** and `unknown` goes to the human.
    Conflating "I looked and it was all code" with "I could not look" is precisely the defect this
    repo keeps finding in its own surfaces.

  Globs are compiled to regex rather than handed to `-like`, which has no `**` and whose `*` crosses
  `/` — under `-like`, `src/*.css` would swallow `src/deep/nested/main.css` and the classification
  would widen with every subdirectory. A project can declare what is visual *for it* (a website
  where the posts are the product), replacing the defaults rather than silently merging with them.

  **This alone changes no behaviour yet** — it adds the vocabulary and the classifier; nothing
  consults them. Said plainly because the alternative is a release note that implies a capability
  the code does not have. `merge` remains in every default contract's irreversible list, so no run
  can merge regardless of class. Wiring it into the merge decision — against the *actual* changed
  paths, at merge time, where the facts exist — is #530, and its review requirement is recorded on
  that issue rather than left as a hope.

  36 tests, mutation-verified: classifying nothing as visual turns 8 red, letting `unknown` pass as
  approved 1, letting a single `*` cross a directory boundary 1, and restoring the
  `TrimStart('./')` bug 1 — that last one found by external review: `TrimStart` takes a character
  *set*, so it ate the leading dot of `.reports/x.md`, and a project pattern like `.reports/**`
  would silently stop matching. A visual change reclassified as code is the one direction that
  costs trust.

### Fixed
- **A reviewer that never reviewed no longer reads as approval** (#510). On PR #508 the
  `claude-review` check reported **success** while the PR ended with **zero** reviews and zero
  comments — twice, on two runs. The gate then printed the same `GATE PASSED` it prints for a
  genuinely clean review, with the self-review reminder as a footnote nobody had to act on. This
  landed in the worst possible window: Copilot has been quota-blocked for weeks, so that workflow
  was the *only* automated reviewer on the repo, and it was passing without reviewing.

  Fixed on both sides:
  - **The workflow now fails when it produced no review.** Publishing the review is part of the
    task, not a side effect — the job was running, exiting clean and leaving nothing because it had
    neither the instruction nor the tool to comment. It now gets both, and a verification step
    turns the check **red** when no review and no `[abios-review]` comment landed.
  - **The gate distinguishes "reviewed, found nothing" from "nobody looked."** A new exit code
    **2 — `GATE SIN REVISAR`** — reports the second case. It is deliberately not 0: any caller
    testing `-eq 0` now fails closed, while still telling an unreviewed PR apart from a genuinely
    blocked one (1). Nothing in the repo branched on the gate's exit code programmatically, so this
    changes no existing behaviour silently.
  - **A reviewer with no GitHub identity can now be counted.** `second-opinion` (Codex) is the
    reviewer that actually shows up here, and it submits no review object — so to the gate it was
    indistinguishable from nobody. `-RecordReview -Reviewer <who> -Summary <what>` writes the
    evidence onto the PR itself, where it survives the session.
  - `-AllowUnreviewed` is the deliberate exception for changes where a review buys nothing (a typo,
    a regenerated file). It prints that nobody read the code rather than implying someone did.

  **All evidence is bound to the PR's head commit**, and external review found that this was the
  whole ballgame. The first cut counted *any* review ever left on the PR, which reproduced the
  original defect one level up: approve, push three more commits, and the gate would authorise a
  diff nobody had read on the strength of a review of different code. Now a GitHub review counts
  only for the commit it was performed on, `-RecordReview` stamps the head SHA into the record, and
  the workflow's verification demands its own marker *for this SHA* — so a run that publishes
  nothing can no longer coast on an earlier run's comment. When evidence exists but belongs to an
  older commit the gate says so explicitly ("empujaste cambios después de que se revisó") instead of
  reporting a bare zero. The cost is deliberate: a new push invalidates the evidence and someone has
  to look again, which is the correct reading — those commits genuinely have not been reviewed.

  `-RecordReview` now **requires** `-Summary`. Without it, it was a one-flag way to stamp "reviewed"
  on a PR nobody read — the same empty assurance as the original bug, with a different author.
  Having to state what the review found is the cheapest available proof that one happened.

  **The root cause, confirmed live** while this very PR was being gated (run 30578175712):
  `claude-code-action` **skips itself and exits `outcome=success`** on any PR that edits its own
  workflow file — a GitHub security measure, so a PR cannot rewrite the reviewer that reviews it.
  Correct as a measure; the problem is that the signal it emits is indistinguishable from "reviewed,
  found nothing". This repo edits that file whenever it tunes the review engine, so it is not an
  edge case. The verification step now names this cause in its error output, and the gate stops the
  deadlock it would otherwise create: **a failing REVIEWER check asks "was this reviewed?", not
  "does the code work?"** — so once a real review is on record for the commit, the reviewer's own red
  is no longer a blocker. Narrow on purpose: one non-reviewer failure and it blocks as before, and
  the failing-check list is read from **structured** data (`gh pr checks --json`) rather than scraped
  from the printed table. That distinction is load-bearing — the first cut parsed the human-readable
  output, where any failure printed in an unexpected shape would drop out of the list, leave a
  reviewer failure as the only one seen, and wave a genuinely broken build through. If the
  structured read fails, the allowance is simply never offered.

  Found while fixing it, by the tests: the marker check used `-like`, whose wildcard syntax reads
  the marker's own square brackets as a character class — it threw instead of matching, which would
  have made **every** external review invisible, i.e. exactly the blindness being removed. 21 tests,
  mutation-verified: treating everything as reviewed turns 4 red, ignoring marked comments 4,
  unbinding reviews from the commit 2, and dropping the fail-closed-without-a-SHA branch 1.

- **The irreversible brake is now a control, not a paragraph** (#516, part of #440). `/board expert
  auto` printed `Brake ARMED` while enforcing nothing: the brake lived only as prose in the launch
  briefing, and an observed run merged its own PR to `main` — closing its epic's sub-issues — while
  every self-report said the brake was on. Instruction alone is what drifted, so the fix is a
  backstop that does not depend on the agent's cooperation:
  - `Start-WorktreeSession` **arms** the run by writing `.agentic-board/brake-armed.json` into the
    launched worktree, carrying that run's own `autonomy.irreversible` list from the contract (so
    the guard and the briefing can never disagree). If arming fails, the session is **not launched**
    — an unarmed run that believes it is armed is precisely the #440 failure.
  - A new **`PreToolUse` hook** (`Brake-PreToolUseHook.ps1`) walks up from the session's cwd, finds
    the marker, and **denies** the tool call before it executes — `gh pr merge`, `Board-Merge.ps1`,
    the REST merge endpoints, and the publish/deploy/refresh/delete paths the contract brakes on.
  - `Board-Merge.ps1` **refuses on its own** inside an armed worktree, so the refusal survives a
    session with no hooks installed or a direct call.

  Two design points worth stating, because both are load-bearing:

  **A git hook could not have done this.** The original suggestion was a `pre-push`/`pre-merge`
  hook, but `gh pr merge` is a server-side API call — no local git operation occurs, so there is
  nothing for a git hook to intercept. The refusal has to happen at the tool layer.

  **The classifier's fail direction is inverted from `Expert-Autonomy`, deliberately.** That one
  classifies an action name from a closed vocabulary, so an unknown verb fails safe (stop and ask).
  This one classifies an arbitrary shell command, where the space of harmless commands is unbounded
  — failing safe there would deny everything and the run could not work at all. So it recognizes
  specific dangerous invocations and lets the rest through. Stated plainly rather than papered
  over: this is a backstop against the known irreversible paths, **not a sandbox**. A novel route to
  the same effect is not caught here; that is what the companion controls (#517 supervisor-side
  detection, #518 auto-clean refusing to destroy the evidence) are for.

  Inside an armed run, any error in the guard **denies** rather than allows. Outside one — an
  ordinary human session, which has no marker — the hook is silent and never interferes.

  **Four bypasses the first cut of this control still had**, found by external review and each now
  closed with its own regression test:
  - A `-DryRun` token **anywhere** on the command line waved through the whole thing, so
    `echo --dry-run; gh pr merge 490` merged. The classifier now splits the command on shell
    separators and judges each segment on its own — a harmless prefix cannot vouch for what
    follows it.
  - Newlines were collapsed into spaces *before* that split, welding a multi-line script into one
    segment and reopening the same hole. A newline is now an explicit separator, which is what it
    means in a shell.
  - The run could **disarm itself**: deleting a local file is otherwise allowed, so
    `rm .agentic-board/brake-armed.json` turned the entire control off in one command. Tampering
    with the marker — deleting it, overwriting it, wiping the state directory, or editing it
    through the file-writing tools — is now refused on its own terms, *not* gated on the
    contract's list. An emptied `irreversible` list reads as tampering too, and falls back to the
    full vocabulary rather than to silence.
  - The REST merge endpoint was only recognised behind `gh api`, leaving the identical request
    open via `curl`, `Invoke-RestMethod`, python or node — all holding the same token. It is now
    matched by **endpoint**, independent of the client.

  **Three more the second review round found**, after those four were closed:
  - **Shell quoting hid the subcommand.** `gh pr 'merge' 490` did not match, and merged. Quote
    characters are now removed during normalization, the way the shell removes them.
  - **A runtime variable is invisible to any string matching** — `$verb='merge'; gh pr $verb 490`.
    Rather than pretend otherwise, a high-risk client reaching for an unresolvable subcommand
    (`gh pr $x`, `gh $x`) is now refused: an autonomous run has no legitimate need to call `gh`
    through a variable, and refusing is the safe side of a call the guard genuinely cannot make.
  - **The hook failed OPEN if its own guard failed to load.** The armed flag was set only after
    dot-sourcing `Brake-Guard.ps1`, so a broken guard left the error handler believing the run was
    unarmed — silently restoring the exact capability the control exists to remove. A
    dependency-free probe now establishes armed-or-not *first*, and everything after it can fail
    without changing which way it fails.

  Arming also **disarms**: a worktree reused from an earlier braked run kept its marker, so the
  hook went on refusing merges for a run whose contract no longer braked on them, while the
  launcher printed `Brake OFF`. The marker now follows the contract in both directions — which is
  what makes that message true rather than another claim the code does not honour.

  **Two more from the third round:**
  - **A line continuation is one command, not two.** `gh pr \`<newline>`merge 490` runs as a single
    command in the shell, but the newline-as-separator rule split it into two harmless-looking
    halves. Continuations (backslash for sh, backtick for PowerShell) are now joined *before*
    newlines become separators.
  - **`MultiEdit` was missing from the hook matcher**, leaving one uncovered write path to the
    marker. Listing a tool this harness may not expose costs nothing; omitting one it does expose
    costs the whole control.

  **Three more from the fourth round:**
  - **A preview claim is now only honoured from something that can preview.** The dry-run
    exemption skipped a whole segment on the token alone, so
    `curl -H "X-Test: --dry-run" -X PUT .../pulls/12/merge` was allowed — a header does not make a
    merge stop mutating. The exemption is scoped to commands that actually have a preview mode.
  - **`gh api` deletes were caught in one spelling only.** `--method=DELETE` and `-X DELETE` issue
    the identical request and went through.
  - **`git push origin :branch`** deletes a remote branch through syntax the `--delete` pattern
    never saw. (`HEAD:main`, an ordinary push refspec, stays allowed.)

  97 tests, and every protection was verified by reintroducing the exact defect it prevents rather
  than by trusting a green suite: stubbing the classifier turns 16 red, a global dry-run exemption
  3, an unprotected marker 6, a `gh api`-anchored REST pattern 4, no quote-stripping 3, no
  variable-indirection pattern 2, joining no line continuations 3, an unscoped preview exemption 2,
  one delete spelling 2, no refspec deletion 1, and deciding the armed flag after the dot-source 1.

  The review ran in rounds until one came back empty. Rounds 1–4 found **12 real defects** — every
  one of them in code whose tests were already green, and four of them in the fix for the round
  before. That is the honest cost of a control this size, and the reason the companion issues
  (#517 supervisor-side detection, #518 auto-clean refusing to destroy evidence) exist: this is a
  backstop against known irreversible paths, not a sandbox.

## [0.28.1] - 2026-07-29
### Changed
- **CI run volume cut ~60 %, and Board Sync no longer triggers itself** (#504; PR #512). The sync
  workflow listened for `assigned` while `board-sync.sh` assigns unassigned issues itself, so its own
  write re-triggered it — every new issue cost at least two runs, the second recomputing a state the
  first had already reconciled. `assigned` is gone, and a burst of issue events now collapses onto one
  run via `concurrency: cancel-in-progress` (safe precisely because the sync is a full-state
  reconciler, not an incremental writer; the telemetry snapshot deliberately does NOT cancel, since a
  half-written run there loses data no later run can rebuild).
  `ci.yml` gates on the **pull request only** — a push to `main` is always a merge of something those
  same jobs already passed, so re-running them after the merge doubled the cost of every change
  without ever catching anything new. `pr-review` and `issue-language` are grouped per PR / per issue
  and cancel superseded runs: addressing gate feedback with three quick commits used to start three
  reviews of three diffs, two already obsolete — which protects the Max review quota, not just
  Actions minutes. Every job now carries an explicit `timeout-minutes` (the default is 360, so one
  hung job could eat 12 % of the monthly quota), and test-log artifacts drop from 90-day to 7-day
  retention.

### Fixed
- **A mature board no longer reports itself empty** (#484). `Board-Work.ps1` read board items with
  `gh project item-list --limit 200`. That call returns exit 0 and exactly 200 items on a bigger
  board — **oldest-first**, so on a mature board the cap fills with Done work and the Backlog falls
  off the end. Against the tool's own 291-item board, `/board work` printed
  `Sin pendientes. Todo el board esta en progreso o terminado.` over **37 open Backlog items**.
  Not a truncation warning — a confident **false all-clear**, landing precisely on the mature boards
  where the stakes are highest, and it silently under-counted the `-ListBoards` board picker the
  same way.
  Board reads now go through `Get-BoardItems.ps1`, which returns `{ Items; Read; Limit; Truncated }`
  and treats a read that reached its cap as **possibly short**. No caller may state an absence off
  one. Every board reader was audited, not just the two in the bug report — the caps ranged from 200
  to 1000 and **six** surfaces were asserting things a short read cannot support:
  - `/board work` says how many items it actually saw instead of "sin pendientes"; the board picker
    renders capped counts as `N+` with an explicit `TRUNCADO` line.
  - `/board complete` **fails closed** — a `PASS` is exactly the absence a short read cannot
    support, and CI would read it as ground truth.
  - `/board triage` no longer prints "(no hay items pendientes)" over an untriaged board.
  - **`/board field apply --merge-conflicts` no longer deletes an option on an unproven verification.**
    The worst of the six: it moves items off a legacy option, checks that none remain, then deletes
    it — and its own comment names the stake ("an item silently losing its Status is data loss").
    The check read with a bare `gh ... --limit 800` and no cap test, so "0 left" could be an
    artifact of the cap. A truncated verification now aborts on the same grounds as a found item.
  - `Backup-Board` refuses to write a partial snapshot: it is the safety net taken *before* a
    destructive operation, so a partial one is worse than none — it would license the delete it
    exists to make reversible.
  - `Export-BoardSnapshot` refuses to publish a truncated `N of M`, and `/board update` publishes
    floors (`N+`) rather than stating a count and retracting it in a footnote.
  - `Set-BoardField` warns *before* its sweep that the pass is partial, instead of printing a
    `set=N` summary that reads like a complete one.
  The shared ceiling is 2000 and costs nothing: `gh` pages the underlying GraphQL 100 at a time, so
  request count tracks the items that exist, not the cap — the old 200 bought no savings and cost
  the truth. Regression tests assert that no script hardcodes its own `item-list` cap and that every
  board reader pulls in the shared one.
  This is the same defect class `Invoke-Gh.ps1` was written for (#303): a read consumed as fact.
  `Invoke-Gh` made a **failed** read loud; this makes a **short** one loud. Neither substitutes for
  the other — a truncated read succeeds.

## [0.28.0] - 2026-07-28
### Added
- **`/board telemetry` — the tool now measures how it actually behaved in real use** (#476;
  PRs #477, #500). 945 local session transcripts on the primary machine, 162 of which really
  invoked the tool, had never been read. Reviewing three of them by hand produced 12 distinct
  defects, 8 previously unfiled, and **not one had been caught by the tool itself** — every one was
  found by a human reading carefully. This verb reads those transcripts and reports where
  agentic-board helped and where it got in the way.
  Transcripts are a valid source because the on-disk file is append-only: compaction shrinks the
  model's context, not the file (verified on a session carrying 30 compaction markers — all 4,125
  events still present). Tool calls are structured records, so "where was the tool invoked and what
  followed" is an exact query rather than an interpretation.
  **Incremental by watermark, never a `scanned` flag** (`Get-FieldLedger.ps1`): the ledger records
  how far each session was read (events + bytes), so "new work" means new sessions *and* grown
  ones, and only the unread tail is parsed. A boolean would retire a session permanently on first
  read and silently lose everything appended later. **Two stages** — a deterministic extractor with
  no model (`Get-FieldEpisodes.ps1`) turns hundreds of megabytes into a few hundred candidate
  episodes; only those are worth a model's attention. The sweep driver is `Invoke-FieldScan.ps1`
  (`-WhatIf`, `-Limit`).
  **Four signals**, all mechanical, none of which reached the board before: **repetition** (an
  action script re-invoked — resolvers and the gh wrapper are exempt, since re-invoking those is
  their contract), **abandonment** (a failure followed by the same job done with bare `gh`/`git` —
  the most valuable and the most invisible: every time the user routed around the tool),
  **correction** (the user reverses what just happened) and **silence** (a failure that went
  nowhere at all).
  Signals were **calibrated against the corpus, not asserted**: `silence` fell from 1,419 hits
  (41.4 % of episodes, i.e. noise) to 99 by requiring a failure; `repetition` fell from 644 to 557
  by exempting resolvers (`Get-GhAccount` repeated on 47.4 % of its calls — its contract, not a
  defect); `abandonment` is deliberately unchanged at 63, which is the evidence the calibration
  sharpened the noisy signals without breaking the one that matters most.
  **Safety, each rule answering an observed failure:** read-only over the transcript store; the
  local record lives at a machine-level root **outside any repo**, so it cannot be committed by
  construction rather than by `.gitignore` config; the watermark advances only after events are
  processed; the ledger is written atomically; and **nothing is filed automatically** — the sweep
  produces candidates for a human to judge.
  First full sweep: **3,425 episodes, 295 failed invocations**, which re-scoped #419 from a
  single-script bug to a 65-failure guard misfire and produced #485.

### Fixed
- **The plugin's own test suite read the checkout's local role catalog** (#460). The classification
  tests called the domain resolver without an explicit catalog, so they merged whatever
  `.agentic-board/roles.json` the working directory held — meaning **any project defining a local
  role broke the plugin's suite**, not just this one. The tests now build the factory catalog from
  the shipped presets and pass it explicitly, with a regression guard asserting both directions: a
  local catalog does change classification, the factory one does not.
  The repo's own `software-engineer` role was also narrowed from 14 keywords to 8, dropping the
  ordinary English words (`script`, `hook`, `gate`, `token`, `scope`, `refactor`) that let a
  high-precedence local role swallow unrelated plans — the same defect filed as #474, applied to
  our own role. Same 15 hooked skills: keywords decide *when* a role is chosen, not what it brings.

## [0.27.1] - 2026-07-28
### Fixed
- **`/agentic-board:expert auto` had no brake — the launched session was *ordered* to merge** (#440).
  `Expert-Auto.ps1` composed `expert-brief-<n>.md` carrying *"STOP before: merge … do NOT merge on
  your own"* and then delegated to `Board-Work.ps1 -Launch`, **which never read that file**. The
  prompt the session actually received came from `Get-SessionBriefing`, which hardcoded
  `(5) merge it (ruleset-safe): Board-Merge.ps1` and closed with *"When the PR is merged … you are
  done"*. A run that merged to `main` — and, on a repo wired to a Git-integration host, deployed to
  production — was not ignoring the brake: it was obeying an explicit instruction. The brake was
  documentation; the order was code.
  Two switches, threaded through all four launch sites: `-StopAtPR` omits the merge step,
  renumbers so `(5)` leaves no gap, and moves the goal to *PR open + review gate green*;
  `-BriefFile` hands the session the brief it never received, taking precedence over the generic
  steps. `Expert-Auto.ps1` derives the brake from the **contract**
  (`Test-IsIrreversible -Action 'merge'`) rather than a default, and prints `Brake ARMED` /
  `Brake OFF`. Plain `/board work -Launch` is unchanged byte for byte.

### Changed
- Registered the three prior-art agent-definition catalogs in the knowledge registry (#459):
  `wshobson/agents` (MIT), `VoltAgent/awesome-claude-code-subagents` (MIT) and
  `hesreallyhim/awesome-claude-code` (CC BY-NC-ND 4.0). All three had been recorded as
  *unlicensed*; `gh repo view --json licenseInfo` returns empty for each, and empty had been read
  as absent.

## [0.27.0] - 2026-07-28
### Added
- **Expert roles are now extensible per project** (#444; #445–#454).
  The five built-in roles moved out of `Expert-RoleSynthesis.ps1` into a shipped
  `presets/roles.json`, alongside the fields/labels/toolkit presets the plugin already ships, and
  a project may add `.agentic-board/roles.json` (versioned in git) to add, extend or override
  roles: `keywords`/`skills` union with the factory role of the same name,
  `agent`/`standards`/`knowledgeDomain` replace it, and `"replace": true` drops the factory values
  entirely. Local roles are evaluated first, so a project can always outrank a factory role, and a
  merged role takes the local position. Before this, any project outside Power BI / semantic
  models / Fabric / plugin-development resolved to `generic`, whose skill list is empty, and the
  only fix was editing the plugin's source.
  A role gives its expert a persona by **pointing at an existing agent definition** (`agents/*.md`,
  the same registry the Agent tool resolves) rather than restating one — inline `standards` remain
  as the shortcut. A plan matching no role is now reported (`roleMatched`) so the expert can
  research the domain, propose a role and persist it with `Add-ExpertRole` **on the user's
  confirmation** — never silently, since it changes how every future plan is classified.
  New `/agentic-board:expert roles` verb (`Expert-Roles.ps1`): `list` prints the effective catalog
  with each role's source and **how many installed skills it actually hooks** — a role that hooks
  zero looks fine on paper and gives the expert no toolset — and `why "<text>"` explains which
  keyword in which role decided a match. A broken local catalog never degrades the expert below
  the factory roles (`ExpertRolesIo.ps1`), and `.gitignore` now exempts `roles.json` from the
  `.agentic-board/` exclusion by excluding the directory's contents, since git cannot re-include a
  file whose parent directory is excluded.

### Fixed
- **`/agentic-board:expert config` produced an unusable role — objective and toolset both empty** (#441, #442).
  Every contract `config` wrote carried a blank objective and no hooked skills; the failure was
  invisible because the test suite called the pure functions directly and never exercised the
  script's own wiring. Three defects: `Expert-Config.ps1` dot-sourced `Expert-RoleSynthesis.ps1`,
  whose `param()` block executes in the caller's scope and reset `$PlanGoal` to `""` (#441 — the
  arguments are now captured before any dot-source); both scripts called `Get-SkillInventory` as a
  function, but the file is a *script* emitting a `{summary, skills, overlaps}` object, so the
  dot-source ran the scan and dumped it to stdout while the swallowed `CommandNotFound` left the
  inventory permanently empty (#442 — new `Resolve-SkillInventory` invokes the script with `&` and
  maps records to names); and `Format-RoleObjective` could never reach its "none installed"
  fallback, because `@($null).Count` is `1` in PowerShell, rendering a bare `- ` bullet instead.
  Repaired alongside them, once the toolset became visible: `Get-HookedSkills` matched against the
  full namespaced string — so the pattern `skill` hooked all 30 skills of a plugin merely named
  `skills-for-copilot-studio` — and a scan crossing git worktrees listed each skill several times.
  Matching is now against the skill name only, with deduplication. New CLI-level tests cover
  `Expert-Config.ps1` end to end.

## [0.26.0] - 2026-07-27
### Added
- **`/agentic-board:expert` — auto-expert mode: run a tracked plan autonomously** (#422; #423–#430).
  A new command that hands a tracked plan to an agent which adopts the required expert persona and
  executes it end-to-end, freeing the user from real-time babysitting. Two verbs:
  `config` (`Expert-Config.ps1`) synthesizes the expert role from the plan's domain — hooking the
  installed skills/profiles for it (`Expert-RoleSynthesis.ps1`) — and writes a contract
  (`ExpertContractIo.ps1`, `.agentic-board/expert.json`); `auto` (`Expert-Auto.ps1`) composes an
  autonomous brief (role + plan + definition-of-done + capability map + the irreversible line) and
  launches a dedicated session in an isolated worktree (reusing the fleet/`-Launch` machinery),
  monitored with `-Sessions -Watch`. **Guiding principle — total self-use of agentic-board:** the
  expert routes every need through existing capabilities (research → `/knowledge`, tooling →
  `/skills`, discover → `/scan`, findings → `/board` issue, survive → `/board handoff`). It records
  test **evidence in three places** (PR body + `[abios-evidence]` issue comment + versioned
  `evidence/<n>.md`, `Expert-Evidence.ps1`), self-heals (in-scope fix / out-of-scope `discovered`
  issue), and brakes **only on the irreversible** (`Expert-Autonomy.ps1`, fail-safe: an unknown
  action is treated as irreversible) — reaching "PR ready" and stopping before merge. `/board plan`
  gains enriched-plan params (`-Research`/`-RoleSeed`/`-Deliverables`/`-TestPlan`) that feed it.
  Internal `board-expert` skill owns the recipe; `/expert` listed in the `/board` menu.
- **`Publish-DocsWiki.ps1` is now the single wiki publisher — includes knowledge registry pages** (#405).
  Previously `Publish-DocsWiki.ps1` (product docs) and `Publish-KnowledgeWiki.ps1` (knowledge registry)
  each cloned the wiki, wrote their pages, and pushed independently, creating a race condition.
  `Publish-DocsWiki.ps1` now generates both sets of pages in one clone → commit → push: product docs
  (`Docs-Home`, `Docs-Command-*`) + knowledge registry (`Home`, `Knowledge-<Domain>`) when
  `knowledge/registry.json` exists. `_Sidebar` now lists all knowledge domain pages alongside the
  product docs links. `Publish-KnowledgeWiki.ps1` is kept as a deprecated thin alias that delegates
  to `Publish-DocsWiki.ps1` for backward compatibility. A new `/docs` command (`commands/docs.md`)
  documents the unified publisher. Use `/docs wiki` for new work; `/knowledge wiki` still works.
- **Wiki docs freshness check in CI** (#406).
  The `docs` job in `ci.yml` now runs `Publish-DocsWiki.ps1 -PagesOnly` on every pull request,
  verifying that wiki pages can be generated from the current `README.md` + `commands/` without
  error and that every generated page carries the `<!-- GENERATED -->` marker.  No git or network
  access — pure generation only.  A broken generator or a removed README now blocks merge immediately
  rather than silently producing a broken wiki on the next publish run.
- **`Publish-DocsWiki.ps1` now generates `_Sidebar.md` + `_Footer.md` for wiki-wide navigation** (#404).
  Every publish now writes two GitHub wiki special pages alongside the product docs pages:
  `_Sidebar` shows a **Product Docs** section (links to `Docs-Home` and each `/command` page)
  plus a **Knowledge** section (link to the knowledge `Home`); `_Footer` carries a
  "generated from the repository" notice so editors know not to hand-edit the wiki.
  Both pages carry the `<!-- GENERATED -->` marker. No new parameters required.
- **`Publish-DocsWiki.ps1` — generate product documentation wiki pages from README + commands** (#403).
  A new script that publishes six pages to the GitHub Wiki: `Docs-Home` (README with HTML stripped)
  and one `Docs-Command-<X>` page per command file in `commands/`. All pages carry a
  `<!-- GENERATED -->` marker so the wiki is clearly derived output, never hand-maintained.
  Supports `-PagesOnly -OutDir` for local preview/testing without git, and `-DryRun` to validate
  without pushing. Same credential-helper pattern as `Publish-KnowledgeWiki.ps1` (token never on
  the command line; uses `Get-RepoFromOrigin` for repo resolution).

### Fixed
- **`/knowledge wiki` now surfaces an actionable error when the wiki is uninitialized** (#402).
  GitHub creates the wiki git repo lazily — it does not exist until the first page is saved via the web
  UI, and there is no REST endpoint to bootstrap it. The previous fallback (`git init -b master`) was
  dead code that always ended with `remote: Repository not found` on push. It is removed; instead the
  script throws a clear multi-step message directing the user to create the first page at
  `https://github.com/<repo>/wiki` and then re-run the command.
- **`Get-RepoFromOrigin` is now the single resolver for ALL origin-deriving scripts** (#392).
  Four scripts — `Board-Merge`, `New-BoardPR`, `Publish-KnowledgeWiki`, `Board-Doctor` — still
  carried their own correct-but-inline derivation after the #281 consolidation. Any future
  improvement to the shared helper (new URL scheme, edge-case fix) would have silently missed
  them. All four now dot-source `Get-RepoFromOrigin.ps1` and call `Get-RepoFromOrigin`, making
  the consolidation complete. A new Pester guard (`Get-RepoFromOrigin.Tests.ps1`) enforces this:
  any script that reads `git remote get-url origin` without sourcing the helper fails CI.

## [0.24.1] - 2026-07-22
### Fixed
- **`#303`-class fail-open hardening batch — four tools that answered confidently instead of failing**
  (#382, #336, #319, #309). Each ships a pure-helper unit test.
  - **`Board-Triage` no longer writes triage onto the tool's own board from a foreign repo** (#382).
    `-Number` defaulted to `13` (agentic-board's roadmap), so an unqualified run (only `-Issue`) from
    any other project silently wrote Type/Area/Estimate onto board #13's item — no error, and #13's
    title in the header was easy to miss. The board is now resolved from the current repo's `origin`
    unless `-Number` is passed explicitly, and an unresolvable board refuses instead of falling back.
  - **`New-BoardPR` no longer phantoms an existing PR and skips creation** (#336). The "is there
    already an open PR?" read was an unchecked `gh pr list`; a phantom row with a null `number`
    counted as "PR exists", so `gh pr create` was skipped and the run reported success with a **blank**
    PR number. The read now fails closed (`Invoke-Gh -Json`) and a PR counts as existing only with a
    positive-integer number.
  - **`/board changelog` no longer stamps a stale version from an ignored worktree copy** (#319). The
    version came from a recursive `plugin.json` search that picked whatever came first — often a stale
    copy inside an ignored `.claude/worktrees/` tree — so `-Write` could insert a duplicate block for
    an already-shipped version. The plugin root is now resolved deterministically (the `plugin.json`
    the script ships beside), never by a recursive sweep, and refuses on genuine ambiguity.
  - **The review gate warns when a PR carries commits from another PR** (#309). Defence-in-depth for
    #294: a commit GitHub associates with a different PR is not this issue's work. Warn-only — it never
    changes the gate verdict (a contaminating commit with no PR of its own stays invisible, documented
    not papered over).

## [0.24.0] - 2026-07-21
### Added
- **`diagram-authoring` skill — Mermaid over ASCII in plugin artifacts** (#375, #376–#379). When the
  agent puts a diagram into a plugin-produced markdown artifact (`/board plan` docs, epic/issue bodies,
  handoffs, status updates, `KNOWLEDGE.md`, README, blog), it now emits a Mermaid fenced block instead
  of hand-drawn ASCII art — GitHub and Claude render it natively, zero build step. A new INTERNAL
  support skill (`user-invocable: false`, never a typed command per the Command Surface Contract) is
  the single source of truth: core rule, diagram-type→syntax decision table, an anti-invention rule,
  a pre-save validation checklist, and an escalation path to D2/Graphviz rendered via Kroki when a
  graph is too dense for Mermaid (#376). `projects-admin` and `knowledge-registry` carry a one-line
  DRY pointer to it (#377). A new **Diagrams** knowledge domain catalogues Mermaid/D2/Graphviz/Kroki,
  and **Graphify** (multi-modal knowledge-graph peer of CodeGraph) is catalogued in `Claude-Code`
  with a sanitization note — referenced, not built (#378). Pester coverage for the skill contract and
  the registry entries (#379).

## [0.23.2] - 2026-07-20
### Added
- **`/board complete` and `/board bi-checklist` sub-actions** (#371). Two capabilities from 0.23.x had
  no typeable verb — contra the Command Surface Contract (#354): the board-full check lived as a bare
  script and the BI release checklist as a doc with no way to surface it. `/board complete` runs
  `Assert-BoardComplete.ps1` (exit 0 when 0 pending, exit 1 lists the offenders — CI-friendly), and
  `/board bi-checklist` prints `references/bi-release-checklist.md` (the [tool]/[external]/[manual]
  definition-of-done for releasing a BI model/report). Command-surface wiring only — no logic change to
  the underlying script or doc; menu entries #20/#21 + projects-admin index rows.

## [0.23.1] - 2026-07-20
### Fixed
- **The review gate stops re-requesting + WAITING for Copilot when the account has no quota** (#367).
  It used to request a Copilot review and wait up to `-TimeoutMinutes` on EVERY PR, even on an account
  with no Copilot (which just answers "unable to review … reached their quota limit") — repeated every
  PR, every session, with no memory. Now, the first time Copilot answers unavailable, the gate records
  it PER ACCOUNT in a `$HOME`-level marker (`CopilotAvailability.ps1`); every later PR — this session
  and future ones — SKIPS the request and the wait and routes straight to the mandatory self-review,
  until a cooldown (`-CopilotCooldownDays`, default 7) expires or `-EnableCopilot` clears it.
  Self-healing (an expired cooldown retries once) and never a gate failure — a skipped Copilot routes
  to self-review exactly like the existing "no Copilot" fallback. Pure `Test-CopilotUnavailableReview`
  / `Get-CopilotSkipDecision` helpers, unit-tested; marker I/O keyed by owner.

## [0.23.0] - 2026-07-20
### Added
- **Compaction-survival for long single-session `/board work` runs** (#348). A queue of issues
  worked in ONE session eventually auto-compacts, and Claude Code's generic summary drops the
  thread. A new `Board-RunLedger.ps1` (`-Start`/`-Update`/`-Close`) keeps a durable run-ledger as
  an `[abios-run-ledger]` comment on the epic plus a lockfile-sized local `.agentic-board/active-run.json`
  marker (#349). The `SessionStart` hook now handles `source: "compact"` — reading only the local
  marker (offline), it re-injects a pointer to the epic ledger so the session re-grounds and resumes
  the queue unattended; a strict no-op outside an active run (#350). A `PreCompact` hook snapshots the
  transcript into `.agentic-board/compact-snapshots/` as a safety net, never blocking (#351). Works
  around three Claude Code limits (no programmatic `/compact`, no auto-compact instructions, no cheap
  compaction model — [anthropics/claude-code#14160](https://github.com/anthropics/claude-code/issues/14160));
  see `skills/projects-admin/references/compact-survival.md` (#352, #353).
- **`Assert-BoardComplete.ps1` — a pass/fail check that the board is fully worked.** Exits 0 when the
  board has zero PENDING items (using the exact `Test-Pending` definition `/board work` lists from: no
  Status, or a Status that means Backlog — incl. legacy `Todo`), exit 1 (listing the offenders)
  otherwise. Run it after a `/board work` sweep, or in CI, to assert a milestone board reached
  zero-pending. Pure `Test-BoardItemPending` / `Get-BoardCompletion` helpers, unit-tested; fails closed
  on a gh error so an unreadable board never reads as "complete".
- **Release checklist spec for BI artifacts** (#17, M4.1). A new
  `references/bi-release-checklist.md` defines "ready to release" for a semantic model / report / PBIP:
  every item is marked **[tool]** (an agentic-board command enforces it — the BPA + TMDL-breaking gate,
  `/board changelog`, `/board triage`, `/knowledge`), **[external]** (a Fabric/PBI capability the tool
  references but does not rebuild — deployment pipelines, refresh validation), or **[manual]** (a human
  judgement the tool surfaces but never fakes — report renders, rollback path). Ships the shared
  definition-of-done plus a copy-paste checklist; wired from the roadmap, `/board changelog`, and the
  projects-admin reference index.
- **Review gate now BLOCKS a merge on semantic-model quality failures** (#16, M3.3). When a PR touches
  a `*.tmdl` model, `Board-ReviewGate.ps1` runs two model-quality gates and stops the merge on either,
  the same way a failing CI check does: the TMDL diff review moves from warn-only to blocking
  (`Tmdl-DiffReview.ps1 -FailOnBreaking` — a BREAKING schema change blocks), and a new
  `Bpa-GateReview.ps1` runs Tabular Editor's Best Practice Analyzer (`-FailOn error` — an error-severity
  violation blocks). Both degrade safely: no model, no committed BPA rules file, or no Tabular Editor
  is a WARN + skip, never a block — a merge is only ever stopped by an actual finding, so a non-BI repo
  is unaffected. `Bpa-GateReview.ps1` parses either CLI's GitHub-annotation output (`te` TE3 or
  `TabularEditor.exe` TE2); pure `ConvertFrom-BpaAnnotations` / `Get-BpaVerdict` helpers, unit-tested.
- **`/board triage` — fill triage fields from evidence, propose Priority under confirmation** (#306).
  Pending items — the only part anyone plans from — sat blank on Type / Area / Estimate / Priority,
  while what little was filled landed in Done, after it could inform anything. `Board-Triage.ps1` closes
  that WITHOUT a bulk default (a uniformly-filled board looks prioritised without being so): `-Pending`
  lists the pending work-list and its blanks; `-Issue <n> -Type/-Area/-Estimate` writes the evidence
  fields the agent infers from the issue's content; and `-Priority Pn -Rationale '...'` only PROPOSES
  (prints) the priority — it writes solely under `-ConfirmPriority`, and refuses a `-Priority` with no
  rationale, because a business priority is a judgement not in the repo and must never be written
  silently. `/board work` now triages on start and `/board` documents it as sub-action 19. New pure
  `Get-TriageGaps` / `Test-PriorityRequest` / `Format-PriorityProposal` helpers, unit-tested.
- **`/board cerrar-ciclo` — a close-the-loop disposition router for the current branch** (#302).
  The careful post-merge teardown (`Invoke-SessionCleanup`) was reachable ONLY through the fleet path
  (`-Sessions -Watch -AutoClean`), so an interactive single session never cleaned up — merged local
  branches piled up until `/board doctor` was run by hand. `Board-Work.ps1 -CloseLoop` classifies the
  CURRENT branch (uncommitted / commits-no-PR / PR-open / PR-merged / PR-closed / merged-advanced) and
  routes it: it PROPOSES the next command for every state and performs exactly one action — tearing
  down a proven-merged local branch in place (switch to default, `git branch -D`, prune the session
  entry; confirm or `-Force`, preview with `-DryRun`), never on a dirty tree, never a merge (that keeps
  the review gate). `Board-Merge.ps1` now also NOTES when its `--delete-branch` left the local branch
  behind (checked out here or in another worktree) and points at `cerrar-ciclo`, instead of silently
  believing it cleaned up. New pure `Get-CloseLoopDisposition` helper, unit-tested across all states.
### Fixed
- **The knowledge registry can live as YAML, so allow-list repos can use `/knowledge`** (#298). A repo
  whose pre-commit hook allow-lists code extensions blocks `knowledge/registry.json` — often on purpose,
  since OAuth `credentials.json` is `.json`, so the barrier that guards secrets also shut the registry
  out of exactly the sensitive-data repos that most want a reference catalog. `Add-KnowledgeRef.ps1
  -Format yaml` now initialises `registry.yaml` instead (`.yaml` is normally allow-listed); every
  `/knowledge` command auto-detects and keeps whichever file exists. A shared `KnowledgeRegistryIo.ps1`
  reads/writes both formats — the YAML is real block style, and every string scalar is serialised
  through the built-in JSON cmdlets (a JSON string token is also a valid YAML double-quoted scalar), so
  URLs with `:`/`#` and notes with quotes round-trip losslessly with no YAML dependency and no
  hand-rolled escaping. JSON stays the default; unit-tested both directions.
- **`handoff -Save` no longer degrades to a silent local-only file when no issue is linked** (#304).
  With no issue resolved (no `-Issue`, no active session, not on an `issue-<n>` branch) `-Save` used to
  write a gitignored `HANDOFF.md` — not portable, and with no MEMORY.md pointer — then say so only
  AFTER writing. It now **refuses before writing** and prints the choice: link it with `-Issue <n>`
  (durable `[abios-handoff]` comment + memo, resumable on another machine) or accept a machine-local
  handoff on purpose with the new `-Local` switch. `-DryRun` reports which of linked/local/refuse it
  would do. New pure `Get-HandoffSaveMode` helper, unit-tested.
- **The CHANGELOG auto-fold now composes with a hand-written `[Unreleased]` block** (#324). `New-Release.ps1`
  folds by delegating to `Board-Changelog.ps1 -Write`, which used to insert the generated block ABOVE any
  `## [Unreleased]` — stranding the maintainer's curated entries under an orphan `[Unreleased]` below the very
  version they belonged to. It now RENAMES `[Unreleased]` to `## [<version>] - <date>` and merges the
  board-derived entries into its sections (preserving hand-written sections like `### Security`, appending
  board lines after the curated ones, never duplicating an already-cited issue). A release that ships only
  curated prose (no newly-Done issues) still gets its `[Unreleased]` renamed. The fully board-generated path
  (no `[Unreleased]`) is unchanged. New pure `Update-ChangelogText`/`Merge-UnreleasedBody` helpers, unit-tested
  both directions.
- **New boards are born on the canonical vocabulary, closing the `Todo`+`Backlog` dead-end** (#299).
  `gh project create` seeds GitHub's default `Status` (`Todo / In Progress / Done`); a board that keeps
  `Todo` can later be duplicated into an unmergeable `Todo`+`Backlog` pair by a plain apply. `Resolve-Board.ps1`
  now applies the preset at creation (`-Lang`, opt out with `-SkipPreset`) while the board is empty, so the
  `Todo`→`Backlog` rename is free and the legacy option never exists. The stale `field-presets.md` guidance
  that sent a `Todo`+`Backlog` board "to the UI" now points at `Apply-FieldPreset.ps1 -MergeConflicts` (shipped
  in #300) and documents why the option must never be re-sent by name (it orphans every item's Status).
- **`/board field apply` was undocumentable-as-typed and easy to misfire** (#297). The `/board`
  `field` bullet named only `Set-BoardField.ps1` (a bulk-fill script) next to "apply a field
  preset", so the preset applier `Apply-FieldPreset.ps1` got reached for by the wrong name; the doc
  now names both scripts distinctly. `Apply-FieldPreset.ps1` also accepts `-ProjectNum` (alias of
  `-Number`, matching the rest of the suite) and `-Preset` (alias of `-Lang`), and its
  missing-preset error now reads `Preset file not found: <resolved path>` instead of the misleading
  `Preset not found: en`.

## [0.22.0] - 2026-07-17
### Added
- **release L1: CI tags + a GitHub Release when `plugin.json`'s version changes on `main`** (#322).
  `.github/workflows/release.yml` cuts the tag `v<version>` and a Release (notes taken from that
  version's CHANGELOG block via `scripts/Get-ReleaseNotes.ps1`) on the exact commit that set the
  version. Idempotency keys on the Release, not the tag, so a hand-created tag still gets its Release.
- **release L2: the marketplace is pinned at a `release` channel, so installs stop tracking `main`
  HEAD** (#323). Both `marketplace.json` entries use a `git-subdir` source at `ref: release`; the
  release workflow fast-forwards that branch to each released commit. Two users on the same version
  string now get the same code (closes the #295 "two codebases" class).
- **skills-ops toolkit catalog** (#331) — a `bi.json` schema with the `microsoft/skills-for-fabric`
  entry, and quality skills migrated to `quality.json`.
- **skills-ops profile-aware bootstrap** (#332) — `Get-SkillGaps -Profile`, plugin-vs-skill-clone
  install, and `/skills bootstrap <profile>`.
- **skills-ops freshness monitor** (#333) — install provenance in `Install-SkillFromRepo`,
  `Get-ToolkitFreshness.ps1`, and `/skills freshness`.
### Fixed
- **Board reads no longer break once a board passes 100 items** (#329). Every paginated Projects-v2
  read built its page-2 cursor as `after: "$cursor"` — PowerShell drops the embedded quotes when it
  hands the argument to `gh.exe`, so the base64 cursor arrived unquoted and its `==` padding parsed as
  bare tokens (`Expected NAME, actual EQUALS`). Latent until a second page existed; at 182 items it
  broke `-Start`, `-ToReview`, `-Parallel`, `-Fleet`, the changelog, the gap-filler and the fleet
  planner at once. The cursor now travels as a GraphQL variable, never spliced into the query text.
- **gh hardening: a `gh` failure is now a failure, not an empty result, across the whole suite**
  (#313, #314, #315, #316, completing #303). The read-then-write paths (Board-Fill, Set-BoardField,
  Resolve-Board, Apply-FieldPreset), Board-Work's ~25 unchecked sites (claims, locks, pending, session
  state), the `gh api graphql` exit-0-with-`errors[]` bodies, and the remaining scripts (Board-Handoff,
  Tmdl-DiffReview, Fleet-*, Board-Changelog, Board-ReviewGate) all fail closed via `Invoke-Gh`.
- **release.yml: the release-existence probe no longer fails its own step** (#339). `gh release view`
  exits 1 when the Release is absent (the intended path), and GitHub's pwsh shell appends
  `exit $LASTEXITCODE`; the probe now clears it so the step exits 0 and goes on to create the release.

## [0.21.0] - 2026-07-17
### Added
- **abios-feedback now writes its issues in English, with a CI backstop** (#305). The English-only
  rule for the tool's own repo lived in three places, none of them loaded when the skill drafts an
  issue from another (often Spanish) project — so 12 of 170 issues drifted to Spanish in two days.
  The rule now lives in the skill itself, and a non-blocking `issue-language.yml` workflow labels any
  opened/edited issue that reads as Spanish (`needs-english`), stripping code fences first so a quoted
  tool error does not trip it. `lang-ok` opts an issue out.
- **`Invoke-Gh.ps1` — a shared helper that turns a `gh` failure into a real failure** (#311, part of
  #303). `gh` signals failure only through its exit code, and a native command that exits non-zero
  does not throw in PowerShell — not even under `$ErrorActionPreference = 'Stop'`. Unchecked, a 401
  becomes an empty result, which several scripts read as "the board is empty" and then write from.
  Covers all three failure modes: non-zero exit, exit 0 with an unparseable body (`-Json`), and exit
  0 with a graphql `errors[]` body (`-Graphql`). Retries only what retrying can fix (5xx/timeouts,
  never a 401), and captures stderr instead of leaving `2>$null` to bury it. A genuinely empty result
  is still returned as empty — that half of the contract is pinned by tests too.

### Fixed
- **A failed backup no longer writes a plausible empty file** (#312, part of #303). `Backup-Board.ps1`
  and `Export-BoardSnapshot.ps1` ran `gh` unchecked, so a 401 produced three empty JSON files and
  printed `Backup OK:` — a failure only ever discovered on restore day. Both now go through
  `Invoke-Gh`, which is what makes a failed read fail. The snapshot is written via `-RawJson`, so it
  is not re-serialised (no reshaping, no silent `-Depth` truncation), and without a BOM, so the same
  backup no longer differs between Windows PowerShell 5.1 and pwsh 7. Each written file is read back
  and parsed before the run reports success. If only the live clone fails, the run still fails but
  now *names* the JSON snapshot it did leave on disk, instead of dying silently over three valid
  files the caller believes do not exist. `Export-BoardSnapshot` no longer publishes a report when it
  could not read the board — including the case where `gh` exits 0 with valid JSON of the wrong
  shape, where `@($resp.items)` on a missing property would otherwise invent a phantom item and
  render `0 of 1 tracked items done.` above an empty table.
- **work: an issue branch starts from the remote default branch, not the current HEAD** (#294).
  `-Start -Branch` cut the branch from whatever HEAD happened to be, so starting an issue from a
  feature branch dragged its unmerged commits into the issue's PR — a 1-line fix opened as 56
  files, +2332/-253, and passed the gate. Both branch paths are fixed (the isolated worktree and
  the in-place `checkout -b`, which had the identical defect), and `-Parallel` no longer hardcodes
  `origin/main`: the default branch is resolved, so a `master` repo works. Basing on the current
  branch is still available for dependent work, now as an opt-in (`-BaseCurrent` / `-Base <ref>`,
  honoured by `-Parallel` too instead of being silently ignored).
- **`field apply --migrate` resolves the legacy/canonical option conflict instead of sending you to
  the UI** (#300). When a plain apply had already created the canonical option beside the legacy one,
  `-Migrate` now moves the items across and deletes the legacy option, rather than reporting a
  conflict it could not act on.

## [0.20.0] - 2026-07-16
### Added
- **Add a way to standardize an existing board onto the canonical preset (field apply cannot migrate; /board work reports a false 'no pending')** (#278)
- **board work: native cross-session lock (/board lock <n>) + PR/commit-aware -Start refusal** (#236)
- **Board-Plan: repo con punto en el nombre se trunca y el script reporta OK sin crear nada** (#281)
- **Board-Work: Test-Pending ignora el Status "Todo" (default de GitHub) -> reporta "Sin pendientes" en falso** (#293)
- **demo: record a GIF/asciinema of a real /board work flow + screenshots** (#210)
- **doctor: post-remove check asks the filesystem, not git — an empty leftover folder keeps the branch alive** (#287)
- **feat(board): /board doctor — audit stale, unmerged and ghost branches from git refs** (#274)
- **feat(work): -Watch mode to auto-detect parallel session completion and auto-clean worktrees** (#135)
- **First-run welcome banner via SessionStart hook (shown once)** (#270)
- **plan: discoverability & adoption** (#207)
- **test: parse every plugin script so a syntax error cannot ship (the $PrLimit: trap from #274)** (#282)
- **work: session teardown asks the filesystem too — a leftover folder leaks the branch and the registry entry forever** (#289)
- **work: teardown can still fail OPEN when the worktree drifted off its branch AND the path strings disagree** (#291)
### Fixed
- **doctor: el guard de terminal interactiva no detecta NonInteractive, y falta -Auto para el caso ya-revisado** (#285)
- **fix(work): AutoClean discards uncommitted worktree work (git worktree remove --force)** (#276)
- **fix(work): AutoClean force-deletes unmerged branches (git branch -D -> -d)** (#273)

## [0.19.0] - 2026-07-13
### Added
- **ci: docs-freshness gate - regenerate + git diff --exit-code (blocks a stale README)** (#203)
- **docs: Update-Docs.ps1 generator - command catalog from frontmatter + version into README markers** (#202)
- **fleet: extend -Sessions dashboard (cli + PID CPU/RAM + log tail)** (#195)
- **fleet: Find-FleetOrphans + Invoke-FleetReap (-Reap / -KillAll)** (#197)
- **fleet: Get-DispatchPlan (wave size from capacity + concurrency cap)** (#193)
- **fleet: Get-MachineCapacity (CPU LoadPercentage + free RAM + cores)** (#192)
- **fleet: Get-SessionGuardSet + Stop-ProcessTree (tree kill, self-exclusion)** (#196)
- **fleet: Invoke-FleetDispatch governor loop (launch in waves)** (#194)
- **fleet: launch-time session marker (ABIOS_FLEET_SESSION) for reaper fingerprinting** (#191)
- **fleet: wire -Stop/-Relaunch/-Reap/-KillAll/-MaxConcurrent + session log redirection** (#198)
- **plan: board fleet - Phase 2 (coordinator + task reaper)** (#190)
- **plan: engineering hardening & DX** (#200)

## [0.25.0] - 2026-07-22
### Added
- **abios-feedback: translate the 12 Spanish issues the English-only rule arrived too late for** (#308)
- **board: expose Assert-BoardComplete as the /board complete sub-action** (#370)
- **Browse + research view: list ALL referenced tools grouped, each row showing its URL; 'research <id>' surfaces the exact reference before installing** (#386)
- **Command surface: add /agentic-board:tools command + internal tools-catalog skill (commands/tools.md + user-invocable:false skill per Command Surface Contract; wire menu + CommandSurface.Tests)** (#384)
- **Install-all (one shot): batch-install every missing installable in a single pass with a dry-run summary + one confirmation; plugin entries listed separately (surfaced, not cherry-picked)** (#388)
- **Pester coverage + docs regen: tests for the resolver + command contract; regenerate README command catalog via Update-Docs.ps1** (#389)
- **plan: /agentic-board:tools ÔÇö unified referenced-tools catalog (browse, research, install individual or all)** (#383)
- **Selective install (individual): install one item by id ÔÇö skill-clone via Install-SkillFromRepo (LICENSE preserved), plugin surfaces its own install command; confirm each, never duplicate** (#387)
- **Unified catalog resolver: merge knowledge/registry.json refs + presets/toolkits/*.json into one item model (name, domain, kind, url, installable, install-method, installed) reusing Get-SkillGaps for installed-detection** (#385)

## [0.18.0] - 2026-07-13
### Added
- **chore: consolidate duplicate plugin.json + wire version bump/changelog into release** (#206)
- **hardening: rename internal state dir .agentic-bi-ops -> .agentic-board (with migration + fallback)** (#244)

## [0.17.0] - 2026-07-10
### Added
- **Multi-CLI fleet for `/board work` (Phase 1 + 1.1)** (#168, #182). Turn `-Parallel -Launch`
  from a Claude-only launcher into a heterogeneous coordinator: a CLI adapter registry
  (claude default + gemini/codex/copilot repl adapters and a jules async adapter), a live
  availability probe with a per-probe timeout and ok/no-quota/auth/error classification, an
  interactive per-issue picker with automatic fallback to claude, and a new `-Fleet` switch —
  reusing the existing worktree + `sessions.json` + Windows-Terminal machinery
  (#169–#180, #183–#186). Headless invocations were discovered live per CLI, never hardcoded.
- **Fleet work-coordination / collaboration layer (Phase 3)** (#238). The parallel fleet now
  *collaborates* instead of merely avoiding collisions:
  - **Shared findings blackboard** — `Fleet-Findings.ps1` (#239): each worktree records
    files-touched / decisions / gotchas in `.agentic-bi-ops/fleet/findings.json` (upsert by
    issue, shared across worktrees); the next session reads it before starting.
  - **File-ownership guard** — `Fleet-Ownership.ps1` (#241): one-owner-per-file with
    boundary-aware overlap detection and dead-PID auto-release.
  - **Advisory board-lead planner** — `Fleet-Plan.ps1` (#240): reads pending issues, orders
    them into dependency waves, and routes each to the best CLI by capability — emits the plan
    (never launches).
  - **Dependency hand-off + briefing wiring** — `Fleet-Handoff.ps1` (#242): a dependent issue
    waits for its blockers and inherits their findings as context. `Get-SessionBriefing` now
    tells each spawned session to read findings, inherit upstream context, claim its files, and
    on completion record findings + release ownership — so the three modules are used in the
    live fleet.
  - **Supervisor** — `Fleet-Supervisor.ps1` (#243): stall detection (past threshold, no PR),
    fleet-complete detection, and a should-stop verdict guarding against a runaway fleet.
- **knowledge-ops module — `/knowledge` (M5)** (#152). A per-project references registry by
  domain (`knowledge/registry.json` + generated `KNOWLEDGE.md`): add/list/harvest/gen/wiki, with
  domain + local-path guards, a health report, and GitHub-Wiki publishing (#153–#162).
- **Discoverability & command-surface UX** (#204, #205, #187–#189, #208, #209). A two-tier
  command surface (only entry-point commands in the `/` palette), a single `/board` index facade
  that routes to every module, a one-line value prop, and an above-the-fold README rewrite.
- **blog-sync + release tooling** (#228–#235). Keep the marketing site synced with releases:
  config schema, tool-state snapshot, gap analyzer, apply+PR flow, and a `/blog-sync` command
  wired into the release flow.
- **Community** (#211–#213). `CONTRIBUTING.md`, good-first-issue labels, issue/PR templates,
  repo metadata, and a distribution checklist.
- **CI: run the Pester suite on every PR, blocking merge on failure** (#201). New
  `.github/workflows/ci.yml` installs Pester 5 and runs the full suite (300 tests) on
  `windows-latest`; any failure fails the `Pester` check. `Board-ReviewGate` waits on it.

### Changed
- **Rebrand: `agentic-bi-ops` → `agentic-board`** (#214). The plugin, marketplace slug, repo, and
  all brand/path references now use `agentic-board`, positioning the tool as a general
  coding-agent-on-a-GitHub-Projects-board platform (BI becomes a future module). Migration is
  non-breaking: a **deprecated `agentic-bi-ops` alias** in the marketplace points to the same
  plugin so existing installs keep updating (#215); the GitHub repo rename relies on GitHub's
  automatic redirect (#216); the in-repo sweep left internal state keys (`.agentic-bi-ops/`
  session dir, `ABIOS_*` env vars) untouched so live sessions, worktrees, and backups are not
  orphaned (#217). See the README "Migrating from agentic-bi-ops" note.

### Fixed
- **Board item lookups are paginated** (#246). `Get-BoardItem` / `Board-Fill` / `Board-Changelog`
  read project items with `items(first:100)` and never paginated, so on a board with more than
  100 items the newest issues were invisible — `/board work -Start/-ToReview/-Parallel/-Fleet`
  failed on recent issues. A pure `Get-AllPages` accumulator now walks every page.

## [0.16.0] - 2026-07-07
### Added
- **Session-handoff module — `/board handoff` (save/resume)** (#137). Stop mid-task and resume in
  a fresh session days later, even on another machine, without re-typing context.
  - **`Board-Handoff.ps1 -Save`** (#139) writes a verified snapshot: frontmatter autofilled from
    git + `.agentic-bi-ops/sessions.json`, a live "Verified git state" block, a `[V]`/`[?]`
    verified-claim ratio, a gitignored `HANDOFF.md` (previous rotated to `.handoffs/`), and a
    durable `[abios-handoff]` comment upserted on the linked issue (the cross-machine source of
    truth). Spec + `[V]`/`[?]` protocol + CREATE-vs-RESUME detection in `references/handoff.md` (#138).
  - **`-Resume`** (#140) reads the latest `[abios-handoff]` comment (or local mirror), rehydrates,
    reports branch/PR **drift**, carries **traps** forward, and offers to start the linked issue.
  - **Auto-memory pointer** (#141): `-Save` drops a self-cleaning `MEMORY.md` pointer (opt-out
    `-NoMemo`) so a new session surfaces the handoff; `-Resume` consumes it.
  - **Opt-in SessionStart hook** (#142, `Handoff-SessionStartHook.ps1`) announces a saved handoff
    on `source: resume`. See `references/handoff-hook.md`.
  - **Security-gated heavy-memory escalation** (#143, `Suggest-HeavyMemory.ps1`): for persistent
    semantic memory, proposes installing **Basic Memory** from upstream (PyPI provenance check,
    pinned exact version, AGPL gate, manager-matched `.mcp.json` entry, reversible uninstall) —
    **never vendored**. See `references/heavy-memory.md`.
  - Docs, `/board` menu option 16, and upstream attribution (Cline Memory Bank Apache-2.0,
    ostikwhy handoff skill MIT) (#144).

## [0.15.3] - 2026-07-06
### Fixed
- **fix(work): parallel `-Launch` opened 8 tabs and mis-parsed comma issue lists** (#131).
  `pwsh -File ... -Parallel 129,130` passed `129,130` as the single string `"129,130"` (cast to
  `[int]` it became `129130`, comma read as a thousands separator), so the batch looked for a
  nonexistent issue. And the launcher fed `pwsh -Command "a; b; c"` to `wt`, which treats `;` as
  its OWN sub-command separator — splitting one intended tab into four (2 issues → 8 stray tabs).
  `-Parallel` is now `[string[]]` split on `,`, and each session launches via a generated
  `launch-<issue>.ps1` run with `pwsh -File` (zero `;` on the `wt` command line).
### Changed
- **Grouped worktree layout.** Parallel sessions now create their worktrees under a single
  `<repo>--worktrees/issue-<n>` folder instead of scattered siblings `<repo>--issue-<n>`, keeping
  the repo's parent directory clean and letting you clean the whole fleet by removing one folder.
- **README** now documents the parallel `/board work` sessions (worktree + Claude session per issue).

## [0.15.2] - 2026-07-06
### Fixed
- **fix(work): the chosen parallel-launch credential is now authoritative** (#127).
  `ANTHROPIC_API_KEY` outranks `CLAUDE_CODE_OAUTH_TOKEN` in Claude Code's auth precedence,
  so picking `-ClaudeAuthVar CLAUDE_CODE_OAUTH_TOKEN` (to bill the subscription) was silently
  overridden by an inherited API key. The launcher now clears every competing Anthropic
  credential before setting the chosen one, and when `-ClaudeAuthVar` is not passed it
  auto-prefers `CLAUDE_CODE_OAUTH_TOKEN` (subscription) when present, else `ANTHROPIC_API_KEY`.

## [0.15.1] - 2026-07-06
### Fixed
- **fix(work): parallel `-Launch` sessions now actually finish the task** (#121, #122, #125).
  The launcher opened tabs that stalled forever: an interactive session blocks on the
  new-worktree trust dialog and the one-time "Bypass Permissions mode" accept, and a `claude`
  child spawned under the Claude Desktop host gets no usable OAuth (401). Each unattended
  session now launches HEADLESS — `claude -p ... --permission-mode bypassPermissions
  --no-session-persistence --verbose` — and authenticates with a credential read at runtime
  from a user-scoped Windows environment variable named by the new `-ClaudeAuthVar` (default `ANTHROPIC_API_KEY`;
  set `CLAUDE_CODE_OAUTH_TOKEN` to bill the subscription). Only the var NAME touches the command
  line — the secret never does — and `-ClaudeAuthVar` is validated as a plain identifier. A
  preflight warns and refuses to spawn if the auth var is unset. NOTE: run `-Launch` from a
  normal terminal, not the Desktop host, which cannot spawn authenticated `claude` children.
- **fix(fill): Board-Fill false 'no gaps' on user-account boards (GraphQL owner resolution)** (#119)

## [0.15.0] - 2026-07-03
### Added
- **feat(work): parallel Claude sessions from /board work** (#98)
- **work parallel: -Parallel batch start (reusable start fn, worktrees, batch safety, dry-run)** (#99)
- **work parallel: docs, /board menu option, and projects-admin reference** (#102)
- **work parallel: launcher spawns a visible Claude session per worktree (Windows Terminal + briefing)** (#100)
- **work parallel: Pester tests for batch parsing, dry-run plan, and safety refusals** (#103)
- **work parallel: register and monitor the spawned session fleet in sessions.json** (#101)
### Changed
- **fix(work): merge step must handle the pr-before-merge ruleset (auto --admin bypass)** (#113)
### Fixed
- **fix(work): review gate false-negative on Copilot review detection** (#115)

## [0.14.1] - 2026-07-03
### Added
- **skills-audit passive Stop hook** (#95, Phase 2): `scripts/SkillAudit-StopHook.ps1` is an
  OPT-IN Claude Stop hook that runs a fast static audit of the current repo's project skills and,
  if there are findings, appends one suggestion line to `.agentic-bi-ops/skill-suggestions.jsonl`
  (gitignored, local) nudging you to run `/skills audit`. Suggest-only: it never opens an issue,
  edits a skill, blocks, or throws — the human stays in the loop. Wiring in
  `skills/skills-audit/references/stop-hook.md`. Not enabled by default.

## [0.14.0] - 2026-07-03
### Added
- **skills-ops — skill lifecycle management module** (#87): manage Agent Skills end to end.
  - **`Get-SkillInventory.ps1`** (#88): read-only inventory across the 3 scopes
    (plugin/personal/project) → normalized JSON with a description lint (the routing surface),
    a budget proxy for the `doctor` health view (1536-char cap), monorepo project inference,
    misplaced detection (knows `.claude/skills` and `plugins/*/skills` canonical layouts), and
    near-duplicate flagging by keyword Jaccard.
  - **`skills-organize`** (#89, #90): report mode (catalog + health) and reorganize mode
    (`Move-SkillsLayout.ps1`) that relocates scattered `SKILL.md` into
    `.claude/skills/<project>/<skill>/` via `git mv` — dry-run default, clean-tree guard,
    `skills-index.json`, exact revert. Never touches the plugin cache or `~/.claude/skills`.
  - **`skills-audit`** (#91, #92): `Invoke-SkillAudit.ps1` classifies failures;
    `Resolve-SkillOwner.ps1` routes each to its OWNING repo (the tool's board for its skills,
    the project's board for project skills, local-only for third-party) so nothing leaks into
    the private project in use. Sanitized filing behind a human gate, `guard-no-private.ps1`
    backstop, plus an on-demand runtime trigger-eval loop.
  - **`skills-bootstrap`** (#93): `Get-SkillGaps.ps1` detects missing recommended skills
    (skill-creator, writing-skills, skill-improver, second-opinion) without duplicating an
    installed one; `Install-SkillFromRepo.ps1` clean-clones each gap preserving the LICENSE.
  - **`/skills`** command (#94): menu routing to organize / audit / bootstrap.
  - 24 Pester tests over temp fixtures. Design recorded in epic #87.

## [0.13.1] - 2026-07-02
### Changed
- **Rename Status `Todo` → `Backlog`** (#84): "Todo" (English "to-do") is a false friend with the
  Spanish "todo" (= all/everything) and read as "all" to Spanish-speaking users. `Backlog` is the
  unambiguous standard Kanban term. Canonical Status is now `Backlog · In Progress · In Review ·
  Blocked · Done`. Updated the preset, the name-keyed detection in `Board-Work.ps1` /
  `Board-Fill.ps1` / `Post-BoardStatusUpdate.ps1`, the sort rank in `Export-BoardSnapshot.ps1`,
  and the docs. The `es` preset keeps `Por hacer` (Spanish is already unambiguous).

## [0.13.0] - 2026-07-02
### Changed
- **Canonical field taxonomy + colors** (#82): established one standard so boards stay coherent
  and `gh` never assigns random option colors again.
  - **Language rule**: board artifacts (Status/Type/labels) default to **English** (universal,
    GitHub-native, matches the commits-in-English convention); the `es` preset stays available
    for explicit Spanish boards.
  - **Canonical Status**: `Todo` GRAY → `In Progress` YELLOW → `In Review` ORANGE → `Blocked`
    RED → `Done` GREEN. The review/testing stage is named **In Review** (renamed from `QA`);
    `Board-Work.ps1 -ToReview` (was `-ToQA`) and `Board-Fill.ps1` (open PR → In Review) key on it.
  - **Field presets** (`fields.en/es.json`) now carry per-option colors; `Apply-FieldPreset.ps1`
    applies them via GraphQL after field creation (gh cannot set option colors on create),
    preserving existing option IDs so item assignments survive. Priority: P0 RED · P1 ORANGE ·
    P2 YELLOW · P3 GRAY.

## [0.12.0] - 2026-07-02
### Added
- **QA stage in the work flow** (#80): the board gains a **QA** Status column (Todo → In
  Progress → QA → Done) so a change moves through testing/review before Done.
  - `Board-Work.ps1 -ToQA <issueNum>`: moves a board item into QA. The `/board work` flow calls
    it right after the PR opens (step 5b), so the item sits in QA while the review gate runs;
    the merge then closes the issue and it lands in Done. Errors clearly if the board has no QA
    option.
  - `Board-Fill.ps1`: an OPEN issue with an **open PR** now maps to **QA** instead of In
    Progress (falls back to In Progress on boards without a QA option).

## [0.11.0] - 2026-07-02
### Added
- **M4.2 — Changelog generation from board items** (`scripts/Board-Changelog.ps1`, `/board
  changelog`): turns the board's Done issues into a Keep-a-Changelog version block, grouping
  them into Added / Changed / Fixed by the board Type field (Feature→Added, Bug→Fixed,
  Docs/Refactor/Chore→Changed; label fallback when Type is empty). Includes only issues closed
  since the most recent CHANGELOG entry AND not already cited as `(#n)`, so shipped work is
  never double-listed. Prints the block; `-Write` inserts it at the top of the CHANGELOG;
  `-Version` / `-Date` / `-Since` override the defaults (version read from `plugin.json`).

## [0.10.1] - 2026-07-02
### Fixed
- **Board-Fill.ps1 cross-account** (#75): the script pinned `GITHUB_TOKEN_PERSONAL`
  unconditionally, so `/board fill` could not operate on a business-account board even with
  `$env:GH_TOKEN` pre-set. Now takes a `-TokenVar` parameter (default `GITHUB_TOKEN_PERSONAL`)
  and respects a pre-set `$env:GH_TOKEN` instead of clobbering it — same contract as
  `Board-Work.ps1`.
- **Board-Fill.ps1 silent failure** (#75): when the project or repo failed to resolve (wrong
  account / missing `project` scope / bad number), the script sailed on and reported "Board
  completo. Sin gaps detectados." Now it aborts loudly with a non-zero exit and a clear message.

## [0.10.0] - 2026-07-02
### Added
- **M2.2 — TMDL diff review** (`scripts/Tmdl-DiffReview.ps1` + `tmdl-review` skill): parses a
  PBIP semantic model's `*.tmdl` before/after a change and classifies every schema change as
  **BREAKING** (table/column/measure/hierarchy/relationship/role deleted, column `dataType` or
  `sourceColumn` changed, column/measure renamed), **WARNING** (measure/partition expression
  changed, `summarizeBy` changed, object hidden, relationship `crossFilteringBehavior` changed)
  or **INFO** (additions, `formatString`/`displayFolder`/`lineageTag`). Two modes: PR mode
  (`-Repo -PR`, reads changed `*.tmdl` via the GitHub API — no clone) and local mode
  (`-Base -Head`, git diff). `-FailOnBreaking` exits 1 on breaking (M3.3 will use it);
  `-Json` emits the findings object.
- **Review-gate integration**: `Board-ReviewGate.ps1` runs the TMDL review automatically when a
  PR touches `*.tmdl` (warn-only — surfaces breaking changes without changing the gate verdict).

## [0.9.2] - 2026-07-02
### Added
- **M2.3 — Cross-account PR workflow** (`scripts/New-BoardPR.ps1`): one command closes the
  work loop on any BI repo regardless of which account owns it. Resolves the account from the
  repo OWNER (CSalcedoDataBI -> `GITHUB_TOKEN_PERSONAL`, PAL-Devs -> `GITHUB_TOKEN_BUSINESS`;
  `-TokenVar` forces one), verifies the login has push permission, pushes the branch through a
  one-shot credential helper (the stored remote is never rewritten and the token never appears
  on the command line or in logs), and opens the PR with `Closes #<n>` — or, on re-run, just
  pushes new commits to the already-open PR (the review-gate iteration loop). `-DryRun`
  previews everything. `/board work` step 5a, the `gh-account` skill, and the `-Start` closing
  message now point here.

## [0.9.1] - 2026-07-01
### Added
- **MS2.2 — Local session registry** (`.agentic-bi-ops/sessions.json`, gitignored, shared
  across worktrees next to the MAIN clone): every successful `-Start` records issue, branch,
  work path, session PID (the long-lived parent process), host and start time. The pending
  list now shows LIVE local sessions ("who works what, where"); dead-PID entries are pruned
  automatically on every read. Completes the multi-session awareness plan.

## [0.9.0] - 2026-07-01
### Added
- **MS2.1 — Automatic worktree mode**: when the working copy is busy (dirty tree or another
  `issue-*` branch — another Claude session active), `Board-Work.ps1 -Branch` no longer just
  refuses: it creates (or reuses) an isolated git worktree `../<repo>--issue-<n>` — the
  official parallel-sessions pattern — and prints where to continue the work, plus the
  `git worktree remove` cleanup for after the merge. Two/three sessions can now work different
  issues of the same repo without touching each other.

## [0.8.9] - 2026-07-01
### Added
- **MS1.2 — Dirty-tree guard** in `Board-Work.ps1 -Branch`: never switches branches under
  another session's feet. If the working copy has uncommitted changes or sits on another
  `issue-*` branch, the switch is refused with the exact `git worktree add` command to work
  the issue in an isolated worktree instead. Re-entry on the SAME issue branch stays allowed.

## [0.8.8] - 2026-07-01
### Added
- **MS1.1 — Multi-session issue lock** in `Board-Work.ps1 -Start`: refuses an issue already
  In Progress + assigned (another Claude session probably has it), showing the last
  `[abios-claim]` fingerprint comment. `-TakeOver` retakes deliberately (dead session /
  handoff) and posts a TAKEOVER claim. Every successful start posts a claim comment
  (hostname, PID, time, branch). GitHub is the lock — works across machines, not just local
  sessions. First piece of the multi-session awareness plan.

## [0.8.7] - 2026-07-01
### Added
- **`/board plan`** (`scripts/Board-Plan.ps1`): turn a plan into a tracked epic + NATIVE
  sub-issues on the repo board — a plan is done when its tasks are issues, not when a markdown
  exists. Two entry modes: plan interactively now, or parse an existing plan doc/plan-mode
  output. Ensures `plan`/`plan-task` labels, reuses `Board-Breakdown` for children,
  `Resolve-Board` for the board (never duplicates), registers epic + children, and hands off to
  `/board fill` + `/board work`. Absorbs the lessons of the personal plan-tracking skill
  (pushed-ref blob URLs only, substantial-tasks-only, current-repo-only) so the flow ships with
  the plugin.

## [0.8.6] - 2026-07-01
### Added
- **M5.7 — Dependency-aware `work`**: pending items labeled `blocked` show as `[BLOCKED]` and
  cannot be started; `-Start` refuses them and also checks native blocked-by dependencies
  (best-effort API), listing the open blocker. `-IgnoreBlocked` overrides a false positive.
  Closes the last M5 gap: every automatable GitHub best practice is now enforced by the tool.

## [0.8.5] - 2026-07-01
### Added
- **M5.6 — `/board update`** (`scripts/Post-BoardStatusUpdate.ps1`): posts a ProjectV2 status
  update (`createProjectV2StatusUpdate`). With no `-Body` it generates one from the live board:
  counts per Status + the next pending items by Priority. `-Status` supports
  ON_TRACK/AT_RISK/OFF_TRACK/COMPLETE/INACTIVE. First update posted on the tool's own board.

## [0.8.4] - 2026-07-01
### Added
- **M5.5 — Small-PR guard** inside the review gate: measures the PR (files, +/- lines) and
  warns over 600 lines / 20 files (tunable `-MaxLines`/`-MaxFiles`), suggesting a
  `Board-Breakdown.ps1` split. A warning, never a block — GitHub PR BP: small focused PRs
  review better and introduce fewer bugs.

## [0.8.3] - 2026-07-01
### Added
- **M5.4 — Sub-issue breakdown** (`scripts/Board-Breakdown.ps1`, wired into work step 4): break
  a large issue into NATIVE sub-issues (`addSubIssue`) so the board's *Sub-issues progress*
  column fills itself as children close. Children get the `task` label and a "Part of #parent"
  body; a CLOSED parent is refused. Task-list checkboxes remain the documented fallback for
  pieces too small to be issues.

## [0.8.2] - 2026-07-01
### Added
- **M5.3 — `/board labels`** (`scripts/Apply-LabelPreset.ps1` + `presets/labels.json`):
  idempotent label taxonomy for any repo. Wired to the suite: `bug`/`docs`/`refactor`/`chore`
  are exactly what Board-Fill Type detection reads, `blocked` is what the work dependency check
  (M5.7) reads, `roadmap`/`plan`/`plan-task` are what plan tracking uses. Never deletes labels.

## [0.8.1] - 2026-07-01
### Added
- **M5.2 — `/board templates`** (`scripts/Install-RepoTemplates.ps1` + `presets/templates/`):
  installs issue forms (`bug`/`feature`/`task` + `config.yml`) and a `PULL_REQUEST_TEMPLATE.md`
  with the mandatory `Closes #` slot into the current repo's `.github/`. Ensures the labels the
  forms reference exist (GitHub silently ignores a form label that doesn't) — `bug` feeds the
  Board-Fill Type detection directly. Existing files are skipped unless `-Force`; the script
  only touches the working copy, committing goes through the normal (PR) flow. Installed on this
  repo as the first consumer.

## [0.8.0] - 2026-07-01
### Added
- **M5.1 — Review gate before merge** (`scripts/Board-ReviewGate.ps1` + work step 5b): no PR
  merges blind anymore. The gate requests a GitHub Copilot code review when available, waits for
  CI checks, waits for the review, prints decision + feedback + unresolved threads, and only
  exit 0 allows the merge. Fallback chain, stated honestly: Copilot → `second-opinion` skill →
  explicit self-review of `gh pr diff`. Closes the only RED gap in the GitHub-flow compliance
  matrix (merge only after approval).
- `Board-ReviewGate.ps1 -InstallRuleset` (optional, once per repo): repository ruleset requiring
  PRs into the default branch; repo admins keep bypass (documented — the hard gate for the agent
  is the work flow itself).

## [0.7.7] - 2026-07-01
### Fixed
- **Destructive false positive in the Status heuristic** (Board-Fill.ps1 AND the board-sync.sh
  CI variant): any merged PR that merely MENTIONED an issue number in its text (e.g. the words
  "board #13" in a PR body) counted as a linked PR and moved that untouched issue to Done — and
  the board's built-in "Done -> close issue" workflow then closed the real issue. Both scripts
  now count only CLOSING references (`willCloseTarget` on the cross-referenced event), for the
  merged->Done rule and the open-PR->In Progress rule alike. Found dogfooding the M5 plan.

## [0.7.6] - 2026-07-01
### Added
- **`/board work` is now interactive about account and scope** (feedback from real use — it
  listed all account boards without asking anything):
  - **Step 0 — account**: if both `GITHUB_TOKEN_PERSONAL` and `GITHUB_TOKEN_BUSINESS` are
    configured, the agent asks which account to use (personal = default); with a single
    configured account there is no question.
  - **Step 1 — scope**: inside a repo clone the agent asks "boards of THIS repo or ALL boards
    of the account?". New `Board-Work.ps1 -ListBoards -Repo <owner/name>` lists only the boards
    LINKED to that repository (`repository.projectsV2`, per-board owner aware); exactly one
    linked board skips the board pick entirely.
- `-Start` now retries once (4s) when the issue was added to the board seconds earlier and is
  not yet visible in the items query (GitHub eventual consistency).
### Fixed
- Restored the `/board init` bullet in `board.md` — it had been mangled into the `work` section
  when 0.7.4 inserted it.

## [0.7.5] - 2026-07-01
### Added
- **Branch + PR finish flow in `/board work`** so the board's *Linked pull requests* system
  column always fills itself: `-Start` now accepts `-Branch` (creates + checks out
  `issue-<num>-<slug>` when the cwd is a clone of the issue's repo), and the flow mandates
  finishing through a PR whose body contains `Closes #<num>` — never a direct commit to main for
  board-tracked issues. Documented that *Linked pull requests* / *Sub-issues progress* are
  system-derived read-only columns: empty Sub-issues progress on a childless issue means "not
  applicable", not a gap.

## [0.7.4] - 2026-07-01
### Added
- **`/board work` — the daily driver** (menu option 1) + `scripts/Board-Work.ps1`: see what's
  pending and start working it. Three modes: `-ListBoards` shows EVERY board of the account with
  its pending count (Todo or no Status) and URL; `-ProjectNum <n>` lists that board's pending
  items sorted by Priority (drafts flagged — convert with `/board fill` first); `-ProjectNum <n>
  -Start <issueNum>` moves the item to In Progress, assigns the owner, and prints the full issue
  context (body, labels, sub-issues) so the agent starts working it in-session. `-DryRun`
  previews the start without mutating; a CLOSED issue is refused with a reopen hint. Respects an
  already-set `GH_TOKEN` (gh-account / `-TokenVar GITHUB_TOKEN_BUSINESS` for the second account).
### Fixed
- Single-select mutations in `Board-Fill.ps1`/`Board-Work.ps1` now pass the option id with
  `gh -f` (raw string) instead of `-F`: option ids are 8-hex-digit strings, and when one happens
  to be all-numeric (e.g. `98236657`) `-F` auto-types it as Int and GraphQL rejects the
  `String!` variable. Found dogfooding `/board work` on the tool's own board.

## [0.7.3] - 2026-06-30
### Added
- `Board-Fill.ps1` now fills **Priority** (P2 Medium), **Size** (M), and **Type** (from labels,
  else Feature) besides assignees/Status; local vars prevent PSObject expansion in `gh -F` args.

## [0.7.2] - 2026-06-30
### Added
- `scripts/Board-Fill.ps1` — interactive gap detection and fill for a whole board, with
  `-DryRun` / `-Auto` modes; converts draft notes to real issues before filling.

## [0.7.1] - 2026-06-30
### Added
- `/board fill` subcommand wired into `projects-admin` + the numbered menu shown when `/board`
  runs without arguments; the board URL is always printed in script output and responses.

## [0.7.0] - 2026-06-30
### Added
- **Bulk-fill a custom field across every board item by rule** — new `scripts/Set-BoardField.ps1`
  + `/board field` recipe. Single-select by title-prefix map (e.g. `Categoria`) or text by `{title}`
  template (e.g. `Ruta`), idempotent, retries transient 502s. Documents the gotchas that bite a manual
  loop (the `cat`=Get-Content alias shadowing, single-select-id vs `--text`, lowercased field keys in
  `item-list`, GraphQL-batch quoting). Turns the "fill all the columns" chore into one command.
- **Post-fill view-visibility warning** in `Set-BoardField.ps1`: after filling, it checks whether the
  field is shown in ANY board view and warns if not — the top "the tool didn't work" false alarm is a
  filled field that the current view simply doesn't display (view columns are UI-only; no API can add
  them). Also documents that `Assignees`/`Linked PRs`/`Sub-issues progress` are auto-derived system
  columns that stay blank on draft cards and cannot be filled by any tool.

## [0.6.2] - 2026-06-29
### Added
- Hard rule + pre-`item-add` check: a board only accepts items from its own anchored repo — a public
  tool's board can never be contaminated with private-project issues (and vice versa).

## [0.6.1] - 2026-06-29
### Fixed
- Board visibility guidance: a board linked from a public repo's docs/showcase must be Public
  (`gh project edit --visibility PUBLIC`). Documented in board-ops + best-practices; applied to the
  showcase board so its links work for everyone.

## [0.6.0] - 2026-06-29
### Added
- `scripts/Export-BoardSnapshot.ps1` — render any board as a Markdown table (a publishable snapshot).
- `SHOWCASE.md` — a self-contained, publishable example: the tool governing its own roadmap board,
  with the dogfooding loop and version evolution. No other repository referenced.

## [0.5.1] - 2026-06-29
### Fixed
- `project-scan` defaults: exclude doc-noise dirs (`.claude/skills`, `.specify`, `templates`) that
  drowned checklist results, and tighten the code-marker regex (case-sensitive + `TAG:`/`TAG(`
  convention) so the Spanish word "todo" and lowercase words are no longer false positives.

## [0.5.0] - 2026-06-26
### Added
- **Safe by design.** `scripts/Backup-Board.ps1` — a COMPLETE backup (JSON snapshot of
  project+fields+items + a restorable live clone) that runs **unconditionally before any board
  delete** (not asked).
- `scripts/Resolve-Board.ps1` — **find-or-reuse** the repo's board so `init`/`add`/plan never create
  a duplicate (fixes the "new board every time" bug). Creates+links+describes only if none exists.
- `references/best-practices.md` — methodology (Kanban base + Scrum-lite fields = Scrumban) and the
  enforced safe-operation rules, with sources.
### Changed
- `projects-admin` SKILL, board-ops, and `/board` now mandate resolve-before-create and
  backup-before-delete; verification checklist updated.

## [0.4.0] - 2026-06-26
### Added
- **Field presets** (`presets/fields.{en,es}.json` + `scripts/Apply-FieldPreset.ps1` +
  `references/field-presets.md`): one-step, idempotent, localized governance fields
  (Status/Priority/Type/Area/Estimate/Target). `/board field apply en|es`.
- **`project-scan` skill + `/scan` command**: scans the CURRENT project for untracked work
  (code TODO/FIXME, doc checklists & "pending" sections, plan/spec docs) and converts chosen items
  into issues + a board plan. Targets the current repo (not the tool's), propose-then-confirm.
### Notes
- Documented that view visibility/layout and renaming the built-in Status field are UI/GraphQL-only.

## [0.3.1] - 2026-06-26
### Changed
- `abios-feedback` hardened with explicit anti-confusion rules: capture is a sanitized issue on the
  CONSTANT target `CSalcedoDataBI/agentic-bi-ops` (never `gh repo view` of the cwd), personal account
  always, no writes to the current project; implementing happens in `$ABIOS_HOME`, not the cwd.

## [0.3.0] - 2026-06-26
### Added
- Coherent `board init`: now also sets the project's short description and README and links the repo
  (`gh project edit --description/--readme`, `gh project link`). Documents that the Default-repository
  pick and View name/layout are UI-only (no gh/GraphQL mutation).

## [0.2.1] - 2026-06-26
### Fixed
- Packaging: the plugin now lives in `plugins/agentic-bi-ops/` with its own `.claude-plugin/plugin.json`
  and the marketplace points to it (`source: ./plugins/agentic-bi-ops`). The previous root-as-plugin
  layout (`source: ./`) was silently rejected by `/plugin marketplace add`. Guard/dev-infra stays at root.

## [0.2.0] - 2026-06-26
### Added
- `abios-feedback` skill — capture tool improvements discovered in any project in a sanitized,
  public-only form (the dogfooding feedback flow).
- Private-content guard: `scripts/guard-no-private.ps1` + `hooks/{pre-commit,pre-push}` +
  `scripts/install-guard.ps1` — blocks any commit/push containing secrets or terms from the
  local-only `.abios/private-denylist.txt`.
- `inbox/IMPROVEMENTS.md` for sanitized improvement notes.
### Changed
- Internal dev docs (`docs/`) are no longer tracked in the public repo (kept local).

## [0.1.0] - 2026-06-26
### Added
- `gh-account` foundation skill (cross-account token resolution, default CSalcedoDataBI).
- `projects-admin` skill + references (board-ops, issue-ops, automation).
- `/board` command.
- Plugin manifest + marketplace entry.
- fix: exclude self-matching lines from secret guard pattern (#1)

