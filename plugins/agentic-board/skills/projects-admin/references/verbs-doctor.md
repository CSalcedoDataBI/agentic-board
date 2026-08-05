# /board doctor — audit branches and worktrees (full recipe)

Loaded on demand by /board (#573).

- **doctor** — audit the local branches and worktrees against GIT REALITY by running
  `scripts/Board-Doctor.ps1` (repo derived from origin, or `-Repo owner/name`). Read-only by
  default: it prints every local branch classified as `merged` (a PR is MERGED **and** its
  `headRefOid` is the branch tip), `merged-advanced`, `in-review`, `closed-unmerged`, `active`,
  `dirty`, `stale` (no PR, tip older than `-StaleDays`, default 30) or `working`, plus any ghost
  worktree git reports as prunable. `-Json` emits the inventory for scripting.
  - Use it when branches/worktrees pile up: the `-Sessions -Watch -AutoClean` teardown only ever
    sees LIVE registered sessions, so anything whose agent died — or that was branched by hand —
    is invisible to every other cleanup path. This is the audit path those paths warn about.
  - `-Fix` is the only destructive mode and confirms EVERY branch (`s/n/t/q`). Yes-to-all is
    offered for the proven-merged pile only; unmerged branches are walked separately, default No,
    with no bulk option. A dirty (or unreadable) worktree is always kept, whatever the class.
  - Do NOT reach for `git branch --merged main` here or suggest it as a cross-check: this repo
    squash-merges, so it reports ~4 of 57 merged branches as unmerged. The PR is the only proof.

The audit path for git refs. Every other cleanup in this tool hangs off `sessions.json`, which is
a **process registry, not a ref inventory**: `Invoke-SessionCleanup` only runs while watching a
LIVE session finish (`Board-Work.ps1 -Sessions -Watch -AutoClean`), and `Read-SessionRegistry`
drops dead-PID entries from every read. So a branch whose agent crashed, a branch made by hand
(`CONTRIBUTING.md` invites them), or a worktree left by a failed remove is invisible everywhere
else. `/board doctor` looks at git instead, and the registry only ever *protects* a branch.

Run `scripts/Board-Doctor.ps1`. Read-only unless `-Fix` is passed.

### The one rule that matters: never use `git branch --merged`

This repo squash-merges (`Board-Merge.ps1 -Method squash`), which rewrites the commits, so a
merged branch is **never** an ancestor of `main`. Measured in a maintainer clone: 61 branches
audited, 57 genuinely merged, and `git branch --merged main` reports **4**. Anything built on
ancestry misclassifies ~51 safely-merged branches as live work. This is the trap #273 hit (PR
#275). A branch is merged iff **a PR for it is `MERGED` AND its `headRefOid` equals the local
branch tip** — the name alone is not enough, because `issue-<n>-<slug>` is deterministic and
`-TakeOver` reuses it, so a stale PR would vouch for new commits. The script does not
re-implement this: it dot-sources `Get-SessionCompletion` from `Board-Work.ps1`, the same pure,
unit-tested verdict the teardown uses, so the two can never drift.

### Classes

| Class | Meaning | `-Fix` |
|---|---|---|
| `merged` | PR MERGED + tip matches — the work landed | deletes (`git branch -D` + worktree), after confirming |
| `merged-advanced` | PR MERGED but tip moved on — merge proves nothing about these commits | never |
| `in-review` | PR OPEN | never |
| `closed-unmerged` | PR CLOSED, not merged | per-branch prompt, default No |
| `active` | a live session owns it (registry) | never |
| `dirty` | worktree holds uncommitted files, or its state is unreadable | never |
| `stale` | no PR, tip older than `-StaleDays` (default 30) | per-branch prompt, default No |
| `working` | no PR yet, recent | never |

Ghost worktrees (git itself reports them `prunable`) are listed separately and cleaned with
`git worktree prune` — no work can be lost there.

`-D` on the `merged` class is **required, not a shortcut**: the squash merge means `-d` refuses a
branch already proven merged by its PR (#273/PR #275). The proof is the PR, not git's ancestry.

### Safety contract

- Read-only by default; `-Fix -DryRun` prints the plan and changes nothing.
- `-Fix` confirms every branch (`s`/`n`/`t`/`q`). `t` (yes-to-all) applies **within the current
  class only**, and the unmerged branches are a separate walk that defaults to No and never
  offers `t` — a bulk yes on the merged pile can never spill onto unrecoverable work.
- A dirty or unreadable worktree is kept whatever the class says, including `merged`: the PR
  proves the *branch* landed, never that the *working files* were saved (the #276/#277
  fail-closed rule). Those keeps are expected states, not alarms — the teardown creates them
  deliberately and says it leaves them "for the audit path".
- Never removes the worktree it is running in.
- Fails closed on every input it cannot vouch for, because an empty answer here is
  indistinguishable from a reassuring one: if `gh pr list` errors or hits `-PrLimit`, if
  `git for-each-ref` / `git worktree list` fails, or if `sessions.json` is corrupt, it refuses
  rather than print "nothing to clean" or hand `-Fix` a list built from missing facts. A broken
  registry blocks `-Fix` only — the read-only audit still works, it just cannot say `active`.
- `-Fix` needs an interactive terminal (the per-branch confirmation IS the safety contract), so
  it refuses under `pwsh -NonInteractive`/CI with an actionable message. `-Fix -DryRun` asks
  nothing and is safe to script.
- `-Fix -Auto` is the "I already read the list, delete them" path (same idea as
  `Board-Fill.ps1 -Auto`), and the only way to clean up from an agent session or CI. It skips
  the prompt for the `merged` class ONLY — the one whose safety is *proven* (MERGED PR +
  headRefOid == tip) rather than judged. Under `-Auto` the unmerged classes are listed and
  **skipped entirely**, never deleted: "cannot ask" resolves to keep. The dirty-worktree and
  current-worktree guards still apply.

## State-dir garbage collection (#574)

`/board doctor` audits git refs; the STATE dir (`.agentic-board/`) has its own reaper:
`scripts/Clear-AbiosState.ps1` (plan only; `-Force` executes; `-MaxAgeDays`, default 14). It
removes only regenerable per-run debris — briefings, launch scripts, expert briefs, per-issue
logs, signal markers, compaction snapshots — never the durable records (sessions history, run
ledger marker, contract, denial log, fleet files), never a live session's files, never anything
it does not recognize. Run it when the state dir has accumulated months of dead runs.
