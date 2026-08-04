# /board work — the daily driver (full recipe)

Loaded on demand by /board (#573): this is the verb's complete contract — follow it exactly.

- **work** — the daily driver: show pending work and start an issue, via `scripts/Board-Work.ps1`.
  Conversational flow — steps 0 and 1 are QUESTIONS: ask, then WAIT for the answer before running:
  0. **Account.** Check which PATs are configured (Windows USER registry):
     `[Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL','User')` and the same for
     `GITHUB_TOKEN_BUSINESS`. If BOTH exist, ask which account to use — `1. CSalcedoDataBI
     (personal, default)` / `2. PAL-Devs (business)` — and for business pass
     `-TokenVar GITHUB_TOKEN_BUSINESS -Owner PAL-Devs` to every Board-Work call. If only ONE
     exists, use it silently — do not ask.
  1. **Scope.** Detect the current repo: `git remote get-url origin` → `<owner/name>`. If the cwd
     is a clone of a GitHub repo, ask: "¿Boards de ESTE repo (<owner/name>) o TODOS los boards de
     la cuenta?" — a repo can have several linked boards.
     - This repo → `-ListBoards -Repo <owner/name>` (only boards LINKED to the repo, via
       `repository.projectsV2`). If exactly ONE board comes back, skip step 2 and continue with it.
     - All / not inside a git repo (skip the question then) → `-ListBoards` (every board of the
       account, most pending first).
  2. **Pick a board.** Show the listing (pending counts + URLs) and ask which board.
  3. **Pick an issue.** Run with `-ProjectNum <n>` — pending items sorted by Priority. Show them
     and ask which issue to start. Draft notes appear flagged: they must be converted with
     `/board fill` before they can be started. Items labeled `blocked` appear as `[BLOCKED]`
     and cannot be started; `-Start` also refuses them (and issues with open native blocked-by
     dependencies) with the blocker listed — `-IgnoreBlocked` overrides a false positive.
     The list also shows LIVE local sessions from `.agentic-board/sessions.json` (who works
     what, where) — dead-PID entries are pruned automatically.
     **Multi-session lock:** `-Start` also refuses an issue already In Progress + assigned
     (another Claude session probably has it — the last `[abios-claim]` fingerprint comment is
     shown). It ALSO refuses when the issue already has a MERGED/OPEN PR or a default-branch
     commit citing `(#n)` — even with no claim comment and the shared bot owner — so a second
     session cannot clobber already-landed work. `-TakeOver` retakes it on purpose (dead session
     / deliberate handoff) and posts a TAKEOVER claim. Every successful start posts a claim
     comment (hostname, PID, time, branch). To reserve an issue for ANOTHER machine without
     starting it here, use `Board-Work.ps1 -ProjectNum <n> -Lock <issueNum>` (posts the LOCK
     claim + moves Status to In Progress; symmetric `-Unlock <issueNum>` releases it).
  4. **Start it.** Run with `-ProjectNum <n> -Start <issueNum> -Branch` — moves the item to
     In Progress, assigns the owner, creates + checks out the work branch `issue-<num>-<slug>`
     (when the cwd is a clone of the issue's repo), and prints the full issue context (body,
     labels, sub-issues). Then CONTINUE WORKING that issue in this session: treat the printed
     context as the task briefing. Always pass `-Branch` when the issue belongs to the current
     repo. `--dry-run` previews without mutating; a CLOSED issue is refused.
     - The work branch always starts from the repo's **default branch, freshly fetched** — never
       from the current HEAD, which would drag the commits of whatever branch you were standing
       on into this issue's PR. For work that genuinely builds on the current branch, opt in with
       `-BaseCurrent` (or `-Base <ref>` for an explicit base).
     - **Busy working copy?** If the folder has uncommitted changes or sits on another
       `issue-*` branch (another session active), `-Branch` does NOT switch — it creates an
       isolated **git worktree** `../<repo>--issue-<n>` automatically (the official
       parallel-sessions pattern) and prints `cd <path>`: CONTINUE THE WORK THERE. After the
       PR merges, clean it with `git worktree remove <path>`.
     - **Too big for one PR?** Break it down FIRST with
       `scripts/Board-Breakdown.ps1 -Parent <issueNum> -Tasks "child A", "child B"` — creates
       native sub-issues (Sub-issues progress fills itself) — then start one child. Use a
       checkbox task list in the parent body instead when the pieces are too small for issues.
     - **Triage it now** (#306). You have just read the full issue context, so this is the moment its
       evidence fields are cheapest to fill: infer Type / Area / Estimate from the content and write
       them with `/board triage -Issue <n> -Type <t> -Area <a> -Estimate <n>`, and PROPOSE a Priority
       (`-Priority P2 -Rationale '...'`) for the user to confirm. Do not leave them blank until Done —
       a field filled after the work is over can no longer inform a decision.
  5. **Finish with a PR + review gate — MANDATORY.** When the work is done:
     a. Run `scripts/New-BoardPR.ps1 -Issue <issueNum>` — the cross-account push+PR step:
        it resolves the RIGHT account from the repo OWNER (CSalcedoDataBI → personal PAT,
        PAL-Devs → business PAT; `-TokenVar` forces one), verifies push permission, pushes
        the branch with a one-shot credential helper (the stored remote is never rewritten
        and the token never hits the command line or logs), and opens the PR with
        `Closes #<issueNum>` in the body — or, on re-run, just pushes new commits to the
        already-open PR (the gate-feedback iteration). NEVER commit board-tracked issue work
        directly to main — the PR is what makes GitHub fill the board's "Linked pull
        requests" column (a system column no API can write). This overrides any general
        commit-directly-to-main workflow rule for issues started via `work`.
     b. Move the board item into **In Review** (the review/testing stage) now that the PR is
        open: `scripts/Board-Work.ps1 -ProjectNum <n> -ToReview <issueNum>`. If the board has no
        In Review column yet, apply the field preset (`/board field apply en`) — it creates the
        canonical Status (Backlog·In Progress·In Review·Blocked·Done) with colors. On boards without
        it, `Board-Fill` keeps mapping open PRs to In Progress, so this step is a no-op — skip it.
     c. Run `scripts/Board-ReviewGate.ps1 -Repo <owner/name> -PR <n>` — it requests a Copilot
        code review when available, measures PR size (warns over 600 lines / 20 files and
        suggests `Board-Breakdown.ps1` — small PRs review better), and when the PR touches
        `*.tmdl` (a PBIP semantic model) runs the two **model-quality gates that BLOCK the merge**
        (M3.3, #16): the **TMDL diff review** (`-FailOnBreaking` — a BREAKING schema change blocks)
        and the **Best Practice Analyzer** (`Bpa-GateReview.ps1 -FailOn error` — an error-severity
        BPA violation blocks). Both skip safely when there is no model / no BPA rules / no Tabular
        Editor, so a non-BI repo is unaffected. It then waits for CI checks, waits for the review,
        and prints decision + feedback + unresolved threads. **Exit 0 = passed; 1 = blocked;
        2 = nobody reviewed.** Address printed feedback with new commits, push, and RE-RUN the gate
        until it passes.
        **Exit 2 — "GATE SIN REVISAR" (#510)** means the checks are green but no one read the code:
        a `claude-review` check can report a PASS having left zero reviews, and that used to print
        the same `GATE PASSED` as a genuinely clean review. **Never merge on exit 2.** Clear it by
        reviewing for real — the `second-opinion` skill is the reviewer that actually shows up here;
        run it in ROUNDS until one returns nothing, verify every finding in the source, then record
        it with `Board-ReviewGate.ps1 -Repo <owner/name> -PR <n> -RecordReview -Reviewer '<who>'
        -Summary '<what it found>'` so the gate can see it. `-Summary` is REQUIRED, and the record
        is stamped with the head commit — so record LAST: anything you push afterwards invalidates
        it, correctly, because nobody reviewed those lines. Only when a review genuinely buys
        nothing (a typo, a regenerated file) use `-AllowUnreviewed`, and say so in your report.
     d. Only after the gate passes: `scripts/Board-Merge.ps1 -PR <n>` — merges the PR (squash +
        delete-branch by default) and, if the repo's own `pr-before-merge` ruleset marks the PR
        `blocked`, retries with the `--admin` bypass the ruleset grants admins (announced honestly);
        a non-admin gets a clear blocked message instead of a raw error. The merge closes the issue,
        which moves the board item from In Review to **Done** (close→Done + `Board-Fill`). Use a raw
        `gh pr merge <n> --squash --delete-branch` only if you deliberately want no ruleset handling.
     - Optional, once per repo: `Board-ReviewGate.ps1 -Repo <owner/name> -InstallRuleset`
       installs a ruleset requiring PRs into the default branch (admins keep bypass — say so).
       `Board-Merge.ps1` handles the resulting `blocked` state for you (auto `--admin` when admin).
  - **Parallel (several independent issues at once).** When the user picks MORE THAN ONE
    independent pending issue, batch-start them instead of looping:
    `scripts/Board-Work.ps1 -ProjectNum <n> -Parallel <n1,n2,...>` starts each (In Progress +
    assign + claim) in its OWN worktree `../<repo>--issue-<n>` off the freshly fetched default
    branch (`origin/main` here — resolved, not assumed, so a `master` repo works too);
    blocked / claimed / closed issues are skipped with a reason (the batch never aborts).
    Add `-Launch` to open one visible Claude session per worktree — a Windows Terminal (`wt`)
    tab when available, else a `pwsh` window — each briefed to take its issue through step 5
    (PR + review gate). `-DryRun` plans (and previews the launch commands) without mutating or
    spawning. Add `-Parallel <nums> -Fleet` instead of `-Launch` to probe the available AI CLIs,
    pick one per issue (auto-fallback to `claude` when a choice is unavailable), and launch each
    in its worktree; `-DryRun` shows the probe table without prompting or spawning.
    Monitor the fleet with `scripts/Board-Work.ps1 -Sessions`, or `-Sessions -Watch -AutoClean`
    to block until every session finishes (PR merged / issue closed / PID dead) and auto-remove
    each worktree + branch + registry entry as it completes (`-DryRun` previews the teardown).
    The teardown is merge-safe: a session whose PR MERGED is torn down as before (the work is
    on the default branch), but one that finished WITHOUT a merged PR (gate blocked, PR closed,
    agent crashed) keeps its branch if it has unmerged commits, and keeps its whole worktree if
    it still holds uncommitted files — auto-clean WARNs naming them instead of destroying the
    work silently. `-ForceDeleteBranch` / `-ForceRemoveWorktree` discard them on purpose.
    Only parallelize issues
    that DON'T depend on each other; clean each worktree with `git worktree remove` after its PR
    merges. Requires Windows Terminal for tabs (Windows-only launcher).
  - If many pending items lack Priority/Size, suggest `/board fill` to triage them first.

## Deep notes (tables, locks, registry, compaction survival)

The daily driver: answers "¿qué hay pendiente?" and starts the chosen issue. Runs
`scripts/Board-Work.ps1` in a conversational flow — steps 0–1 are questions the agent must ASK
and wait for; never assume the account or the scope:

| Step | Command | What it does |
|------|---------|--------------|
| 0. Ask account | (registry check, no script) | If BOTH `GITHUB_TOKEN_PERSONAL` and `GITHUB_TOKEN_BUSINESS` exist in the Windows USER registry, ask which account (personal = default); only one → use it silently. Business → pass `-TokenVar GITHUB_TOKEN_BUSINESS -Owner PAL-Devs` everywhere |
| 1. Ask scope | `git remote get-url origin` | Inside a GitHub repo clone, ask: boards of THIS repo or ALL boards of the account? Outside a repo, skip the question (= all) |
| 2. Pick a board | `Board-Work.ps1 -ListBoards [-Repo <owner/name>]` | With `-Repo`: only boards LINKED to that repo (`repository.projectsV2`) — exactly one result skips this pick. Without: every board of the owner (backups excluded). Both show pending count (Backlog or no Status) + URL, most pending first |
| 3. Pick an issue | `Board-Work.ps1 -ProjectNum <n>` | That board's pending items sorted by Priority; drafts flagged (convert via `/board fill` first) |
| 4. Start it | `Board-Work.ps1 -ProjectNum <n> -Start <issueNum> -Branch` | Status → In Progress, assign owner, create + checkout branch `issue-<num>-<slug>`, print full issue context (body, labels, sub-issues) |
| 5. Finish it | push branch → PR with `Closes #<num>` → `Board-ReviewGate.ps1 -Repo <owner/name> -PR <n>` → `Board-Merge.ps1 -PR <n>` only on exit 0 | Review gate (GitHub flow: merge only after approval): requests Copilot review when available, waits for CI checks + review, reports decision/feedback/unresolved threads. **Exit 1 = blocked** → fix, push, re-run. **Exit 2 = nobody reviewed** (#510) → see below. Merge via `Board-Merge.ps1` (auto `--admin` when the `pr-before-merge` ruleset marks the PR blocked). Then GitHub fills **Linked pull requests** by itself |

Notes:
- Step 4 supports `-DryRun` (preview, no mutation). A CLOSED issue is refused with a reopen hint.
  It retries once (4s) if the issue was added to the board seconds ago (eventual consistency).
- After step 4, the agent continues working the issue in-session — the printed context is the briefing.
- **Gate exit 2 — "GATE SIN REVISAR" (#510).** Checks are green but *nobody looked at the code*: no
  GitHub review, no registered external review. This used to print `GATE PASSED` with a reminder
  underneath, so a green `claude-review` check that had left **zero** reviews read as approved —
  in the exact window where it was the only reviewer (Copilot quota-blocked). Do **not** merge on
  exit 2. Resolve it one of two ways:
  1. **Review it for real**, then record it so the gate can see it:
     `Board-ReviewGate.ps1 -Repo <owner/name> -PR <n> -RecordReview -Reviewer '<who>' -Summary '<what it found>'`.
     The `second-opinion` skill is the reviewer that actually shows up here; run it in **rounds
     until one returns nothing**, verify each finding in the source, and only then record.
     `-Summary` is **required** — a record with nothing to say is the same empty assurance the
     issue is about. The record is stamped with the head SHA, so **record last**: any commit pushed
     afterwards invalidates it, and correctly so (nobody has reviewed those lines).
  2. **`-AllowUnreviewed`** when a review genuinely buys nothing (a typo, a regenerated file). It
     says out loud that nobody read the code — use it as the exception, never as the routine path.
- **Step 5 is mandatory**: never commit board-tracked issue work directly to main. `Linked pull
  requests` and `Sub-issues progress` are system-derived, read-only columns — the ONLY way to fill
  Linked PRs is finishing through a PR that closes the issue; Sub-issues progress only applies to
  parent issues with native sub-issues (empty = not applicable, not a gap).
- **Review gate fallbacks** (in order): Copilot code review (auto-requested) → `second-opinion`
  skill as extra reviewer → explicit self-review of `gh pr diff` (must be stated honestly in the
  report). "No checks configured" counts as pass with a hint to run `/board automate`.
- **Small-PR guard** (in the gate): warns over 600 changed lines / 20 files (tunable via
  `-MaxLines`/`-MaxFiles`) and suggests `Board-Breakdown.ps1`. Warning, never a block.
- `Board-ReviewGate.ps1 -Repo <owner/name> -InstallRuleset` (optional, once per repo) installs a
  ruleset requiring PRs into the default branch; repo admins keep bypass — never claim it blocks
  admins. That ruleset makes `gh pr merge` return `blocked` (needs `--admin`), so **finish the
  merge with `Board-Merge.ps1 -PR <n>`** — it retries with the admin bypass automatically and says
  so, or reports a clear block for a non-admin. A raw `gh pr merge` is the escape hatch only.
- **Dependency check**: pending items labeled `blocked` show as `[BLOCKED]` and `-Start` refuses
  them, plus any issue with OPEN native blocked-by dependencies (best-effort API), listing the
  blocker. `-IgnoreBlocked` overrides a false positive; remove the `blocked` label when unblocked.
- **Multi-session lock**: `-Start` refuses an issue already In Progress + assigned (shows the
  last `[abios-claim]` fingerprint comment: hostname, PID, time, branch). `-TakeOver` retakes it
  deliberately and posts a TAKEOVER claim. GitHub is the lock — it works across machines too.
- **PR/commit-aware refusal**: `-Start` also refuses when the issue already has a **MERGED PR**,
  an **OPEN PR**, or a default-branch **commit citing `(#n)`** — even with NO `[abios-claim]`
  comment and the shared bot owner (a session can land work on `main` without posting a formal
  claim). This stops a second session from clobbering already-merged work. `-TakeOver` overrides.
- **Explicit lock (`-Lock <n>` / `-Unlock <n>`)**: mark an issue owned-elsewhere in ONE step —
  posts the `[abios-claim]` LOCK fingerprint AND moves Status to In Progress — WITHOUT starting or
  branching it locally (needs `-ProjectNum`). Symmetric `-Unlock <n>` posts an UNLOCK claim and
  moves Status back to Backlog. Use it to reserve an issue for another machine/session. `-DryRun`
  previews.
- **Session registry**: every successful `-Start` records `{issue, branch, workPath, sessionPid,
  host, started}` in `.agentic-board/sessions.json` next to the MAIN clone (shared across
  worktrees, gitignored). The pending list shows live local sessions; entries with dead PIDs are
  pruned automatically on read.
- **Compaction-survival (long single-session queues)**: when you work a queue of issues tied to an
  **epic** in ONE session, keep a durable run-ledger so the run survives auto-compaction. Three
  touch-points (see [references/compact-survival.md](references/compact-survival.md)):
  - When you begin the queue: `Board-RunLedger.ps1 -Start -Epic <n> [-Board <b>] [-Queue <n,...>]`
  - After each issue's PR merges: `Board-RunLedger.ps1 -Update -Epic <n> -Issue <i> -Note "<decision/gotcha>" -Next "<next step>"`
  - When the queue is done: `Board-RunLedger.ps1 -Close -Epic <n>`

  The ledger lives as an `[abios-run-ledger]` comment on the epic (durable) plus a local
  `.agentic-board/active-run.json` marker (a lockfile-sized breadcrumb). If the context
  auto-compacts mid-run, the `SessionStart(compact)` hook re-injects a pointer to that ledger so
  the session re-grounds and resumes the queue unattended. Opt-in per run and a **strict no-op**
  otherwise — no marker means the hook stays silent. Keep entries lightweight (a decision, a
  gotcha, the next step); the board remains the source of truth for per-issue **status**.
- **Worktree mode**: when the working copy is busy (dirty tree or another `issue-*` branch),
  `-Branch` creates/reuses an isolated worktree `../<repo>--issue-<n>` instead of switching —
  the agent must continue the work in the printed path and `git worktree remove` it after the
  merge. Same-issue re-entry in the main clone stays a plain checkout.
- `-Branch` skips branch creation (with a warning) when the cwd is not a clone of the issue's repo.
- Skip steps 1–2 when the user already named a board.
- The script respects an already-set `GH_TOKEN` (from gh-account); otherwise it reads `GITHUB_TOKEN_PERSONAL` (or the var given in `-TokenVar`).

### Parallel mode — start several independent issues at once

When step 3 shows more than one issue the user wants to advance simultaneously, batch-start
them instead of one-by-one (each still finishes through the same step 5):

| Command | What it does |
|---------|--------------|
| `Board-Work.ps1 -ProjectNum <n> -Parallel <n1,n2,...>` | Batch-start each issue (In Progress + assign + claim), each in its OWN isolated worktree, branched off the freshly fetched **default branch** (resolved, not assumed — a `master` repo works). Blocked / claimed / closed issues are skipped with a reason — the batch never aborts |
| `... -Start <n> -Branch -BaseCurrent` (or `-Base <ref>`) | Opt in to basing the issue branch on the current HEAD (or an explicit ref) instead of the default branch — for work that genuinely builds on the branch you are standing on. Also honoured by `-Parallel`. Without it, the branch always starts from the default branch, so the PR cannot drag another branch's unmerged commits (#294) |
| `... -Parallel <nums> -Launch` | After starting, spawn ONE visible Claude session per worktree, each briefed to take its issue through step 5. Windows Terminal tab (grouped in one named window) when `wt` is on PATH; otherwise a standalone `pwsh` window per worktree |
| `... -Parallel <nums> [-Launch] -DryRun` | Plan the whole batch (and, with `-Launch`, preview the exact launch commands) without mutating the board, touching git, or spawning anything |
| `Board-Work.ps1 -Sessions` | Monitor the LIVE fleet from `sessions.json` (branch, worktree, launch method `via`, and the PR opened per branch). Dead-PID entries pruned on read; needs no `-ProjectNum` |
| `Board-Work.ps1 -Sessions -Watch [-AutoClean]` | BLOCK polling each session until it finishes (PR MERGED / issue CLOSED / host PID dead), printing progress every `-WatchPollSec` (default 30s) up to `-WatchTimeoutSec` (default 1800s). With `-AutoClean`, tear each finished session down as it completes: kill the tab shell FIRST (the `pwsh -NoExit` left cwd'd in the worktree holds a handle → `git worktree remove` would fail), then `git worktree remove --force` + the branch delete + prune its `sessions.json` entry. The branch delete is merge-safe (#273): a session whose PR **MERGED** is force-deleted as before (the work is on the default branch; local ancestry can't prove this because the flow squash-merges), but one that finished **without** a merged PR (gate blocked, PR closed, agent crashed) is deleted with the safe `git branch -d` — git refuses it, the branch SURVIVES, and the teardown WARNs (in yellow) naming branch + issue instead of destroying the commits silently. Pass `-ForceDeleteBranch` to discard such a branch on purpose. The worktree removal is guarded the same way (#276): an unmerged session whose worktree still holds uncommitted/untracked files is NOT removed — the teardown WARNs with the file count and keeps worktree + branch + registry entry so a later run can retry; `-ForceRemoveWorktree` discards it on purpose. A merged session is torn down as before (its work landed). Also runs after `-Parallel <nums> -Launch/-Fleet -Watch`. `-DryRun` prints the teardown plan without touching git or killing anything (#135) |

- **Only for INDEPENDENT issues.** Never parallelize a chain where one depends on another's
  merge — run those sequentially. The user picks which issues are safe to run together.
- **Each spawned session finishes through step 5** (PR `Closes #<num>` → review gate → merge).
  The briefing is written to `.agentic-board/briefing-<n>.txt` and read by the session, so no
  long prompt ever hits the command line.
- **Requires Windows Terminal (`wt`)** for grouped tabs; without it each session opens in its own
  `pwsh` window (still works). Windows-only launcher.
- **Clean up** each worktree after its PR merges: `git worktree remove ../<repo>--issue-<n>`.
- PID tracking is reliable for the `pwsh` fallback; a `wt` launcher forks the terminal host and
  exits, so those entries keep the host session's PID (documented limitation).

