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
  2b. **State of play — it comes FIRST, before the pending list (#660).** "What is pending?",
     "pendientes", "qué hay en proceso" and every other phrasing of that question are NOT answered
     by the board's Backlog alone: the same `-ProjectNum <n>` run opens with an `Estado del
     trabajo` block that reads five more sources from the things that execute them — the run
     marker (`.agentic-board/active-run.json`), the epics with every sub-issue closed, the
     worktrees whose branch already merged, the open issues that are not on the board, and the
     `[Unreleased]` CHANGELOG block of the default branch. It also lists what is IN FLIGHT (board
     items In Progress / In Review, open PRs, a run whose queue is still open). **Read it to the
     user in their terms, then act on the findings — never answer with the pending list alone.**
     It is read + offer only: the script changes nothing on GitHub and nothing tracked in the repo (like the rest of the listing it may create the gitignored local state folder), and each finding carries the offer.
     **Never print a command for the user to run** — on a yes, YOU perform the disposition, through
     the verb that owns it, with that verb's usual confirmation:

     | Finding | On a yes, you… |
     |---|---|
     | Run still `active` but its queue/epic is closed | `Board-RunLedger.ps1 -Close -Epic <n>` (marks the marker closed and updates the ledger comment) |
     | Epic open with every sub-issue closed | close the epic issue (`gh issue close <n> --reason completed`) and let `Board-Fill` move it to Done |
     | Worktrees of branches already merged | `/board doctor -Fix` — per-branch confirmation, dirty worktrees kept |
     | Open issues not on the board | `/board add` for each (references/issue-ops.md), then `/board fill` to set their Status/Priority/Size |
     | `[Unreleased]` waiting for a release | the release flow (`New-Release.ps1`) — never tag or publish without the user's go-ahead |

     A source that could not be read appears under `No pude comprobar` — say so; it is NOT "clean".
     A repo with nothing to report prints ONE line (`sin novedades`) and goes straight to the
     pending list. The marker, worktrees and CHANGELOG belong to the CLONE you stand in, so they are
     skipped (and the line says so) when `-Repo` names a different repository.
  3. **Pick an issue.** The pending items follow the state of play, sorted by Priority. Show them
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
  3b. **Decide the PR shape BEFORE starting anything — grouped is the default (#662).**
     The per-PR cycle is what costs the user: one review-gate run against the subscription
     quota, a `second-opinion` round whenever no real reviewer shows up, and a merge
     confirmation that needs their attention. That is paid ONCE PER PR, not per issue — so on
     a board of related issues it dominates the cost of the work itself. **When the chosen
     issues overlap, they go in ONE PR.** One PR per issue is the case that needs a reason:
     - the issue carries risk that should be able to fail review on its own, or
     - someone should be able to approve or reject it separately from the others, or
     - the repo said so (`preferGroupedPRs: false`, below).

     `Board-Work.ps1 -ProjectNum <n>` does this arithmetic for you: under the pending list it
     names the groups it found, **the evidence for each** (the same file of this repo named in
     both issues, or a shared board Area), and how many review rounds grouping would remove.
     Read the evidence, not the count — the tool proposes, you decide. It caps a group at 4
     issues so the PR stays reviewable, and says out loud which issues it held back for a
     second batch. Never merge the leftovers back in silently: an unreviewable PR trades a cost
     the user pays knowingly for one they do not.

     **The repo's standing answer.** `Board-Work.ps1 -PreferGroupedPRs on|off|auto` records it
     in `.agentic-board/config.json` (versioned, like `roles.json` — it is a team decision, not
     machine state). `on` = group whatever overlaps without asking each time; `off` = one PR per
     issue, and the offer stops appearing; `auto` = the default, propose it and let the user
     decide. **Ask once, then record it** — a preference the user has to restate every session is
     not a preference. Recording it needs no GitHub token: it is a local decision, so it works on
     a machine with no PAT configured.
     **Seeing it.** `Board-Work.ps1 -PreferGroupedPRs show` prints the current setting and where
     it came from — `PRs agrupados: on (config del repo)`, or `auto (por defecto)` when the repo
     recorded nothing (a recorded `auto` is stored as "no decision", so it also reads `por
     defecto`). It writes no preference and needs no token, and outside a git repo it answers `auto
     (por defecto)`. The `/board` menu runs it to show the value under `work`, and every group the
     pending list proposes says which setting produced it and how to change it (#681).

     Note what `on` does NOT mean: it never invents a group out of issues that share nothing.
     There is no honest way to batch two unrelated issues, and a group with no reason behind it
     is what this whole feature refuses to produce. When nothing overlaps under `on`, the tool
     SAYS so — going silent would be indistinguishable from `auto` having nothing to report, and
     the repo's standing preference would look ignored. A corrupt config file is reported too,
     never silently read as "no preference".

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
     - **Busy working copy?** If the folder has uncommitted changes, sits on another
       `issue-*` branch (another session active), or is CLEAN but stands on a feature branch that
       carries commits the default branch lacks (live work is as busy as a dirty tree — #670),
       `-Branch` does NOT switch — it creates an
       isolated **git worktree** `../<repo>--issue-<n>` automatically (the official
       parallel-sessions pattern) and prints `cd <path>`: CONTINUE THE WORK THERE. After the
       PR merges, clean it with `git worktree remove <path>`.
     - **Starting a group?** Use `-StartGroup <n1,n2,...> -Branch` instead of running this step
       once per issue: the first issue gets the branch/worktree and the rest get only the board
       mechanics (Status/assignee/claim) on that SAME branch, so they finish through ONE PR,
       one gate and one merge. This is the normal path for issues the offer grouped, not a
       special case — see step 3b for when to split them back out instead.
     - **Too big for one PR?** Break it down FIRST with
       `scripts/Board-Breakdown.ps1 -Parent <issueNum> -Tasks "child A", "child B"` — creates
       native sub-issues (Sub-issues progress fills itself) — then start one child. Use a
       checkbox task list in the parent body instead when the pieces are too small for issues.
     - **Triage it now** (#306). You have just read the full issue context, so this is the moment its
       evidence fields are cheapest to fill: infer Type / Area / Estimate from the content and write
       them with `/board triage -Issue <n> -Type <t> -Area <a> -Estimate <n>`, and PROPOSE a Priority
       (`-Priority P2 -Rationale '...'`) for the user to confirm. Do not leave them blank until Done —
       a field filled after the work is over can no longer inform a decision.
  5. **Finish with a PR + review gate — MANDATORY.** What is mandatory is that the work lands
     through a PR and a gate, NOT that each issue gets its own: a batch started at step 3b
     finishes through one PR carrying one `Closes #<n>` per issue. **Commit with an explicit
     pathspec** — `git commit -m "<msg>" -- <paths>` — never `git add <paths>` followed by a bare
     `git commit`: the bare form takes whatever else is staged in the index, so if another session
     ever touches the same folder your commit carries its files under your message (#547).
     `New-BoardPR.ps1` also refuses to push a branch other than the one a live session registered
     for the issue in this working copy (`-AllowBranchMismatch` overrides on purpose). When the
     work is done:
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
        2 = nobody reviewed; 3 = CI never ran (#481).** Address printed feedback with new commits,
        push, and RE-RUN the gate until it passes.
        **Exit 3 — "CI NO SE EVALUO" (#481)** means the only blocker is that CI never executed a
        step (`startup_failure`, or a job GitHub refused to start — exhausted Actions minutes, a
        spending limit, no runner). It is still a block, never a pass, but no code change can clear
        it: **do not re-push**. Tell the user the CI could not run (quota / billing / workflow) and
        let them decide; a real failing check keeps exit 1.
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
     d. **Before asking to merge, present a merge-confirmation summary — MANDATORY (#630/#631).**
        Merging is the one step in this flow you still confirm with the user each time (it is
        `git push`'s harder-to-undo cousin), and "gate passed, ¿mergeo?" on its own forces them to
        either trust blindly or go re-read the diff themselves — the two outcomes this summary
        exists to avoid. Post it in the user's language, in plain terms (no script/file names, no
        commands to paste), with exactly these four parts:
        - **Qué hice para aprobarlo** — the problem in one sentence, the fix in plain terms, and
          why any deliberate design choice (an opt-in flag, a scope limit) is shaped that way.
        - **Qué verifiqué antes de darlo por bueno** — the concrete checks that ran (tests, and
          which reviewers actually left a review — name them) and what, if anything, they found
          and how it was resolved. Do not just say "tests pass" — say which ones and why those.
        - **Qué debes esperar después de mergear** — what changes for the user today (often
          "nothing yet — this lands the mechanism, the next issue wires it in") and what does not.
        - **¿Mergeo?** — the explicit question. Wait for the answer; do not merge on a
          non-answer or a topic change.
        This is not the four-block closing summary from `#491` (that one is a generic end-of-turn
        report, always present, format fixed by a shared renderer) — this is specific to the
        moment right before an irreversible action, and its content is about THIS PR, not the
        whole session.
     e. Only after the gate passes AND the user confirms: `scripts/Board-Merge.ps1 -PR <n>` — merges the PR (squash +
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
    **Launch surface (`-Surface`, #710 P1).** `-Surface terminal` (the default) is the wt-tab/pwsh
    behaviour above, byte-for-byte. `-Surface app` is for a host app (the Claude desktop app's Code
    tab, an IDE) where the user wants each issue as its own VISIBLE session in the host's own
    sidebar — a script cannot open one, only the agent can, via the host's session-spawn tool. On
    `-Surface app` the script creates **no worktree and spawns no process**: it does the board
    mechanics (Status/assignee/claim) exactly as above, then emits a **dispatch manifest**
    (`-Json` for raw JSON) — one entry per issue with `issue`, `title`, `repo`, `branch`, a
    self-contained `briefing`, `ownedPaths` and a shared `runId`. With `-Json`, stdout carries the
    manifest and **nothing else**: the batch's human progress lines are suppressed for that one flag
    combination, so `ConvertFrom-Json` on the captured output works (errors still go to stderr and
    the exit code still reports failure). Hand each entry to the host's
    session-spawn tool (this needs ONE click per task — a host constraint, said plainly, never
    faked), then record the id it returns: `Board-Work.ps1 -RegisterSession -Issue <n>
    -HostSessionId <id>`. That id is what keeps the session visible and alive in `-Sessions`: a
    host-managed row has no PID this script can ever see, so liveness for it is never a PID check
    (completion is a later channel — a host end-signal + `Fleet-Supervisor.ps1 -Check`, #710 phase
    3). `-Surface headless` is accepted (so callers can name it) but not yet implemented — it
    throws rather than silently falling back to a visible terminal.
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
| 3a. Read the state of play | (printed at the top of the same run) | **`Estado del trabajo` (#660)** — what is in flight (board In Progress / In Review, open PRs, a run with an open queue) and what is stale or due: a run marker still `active` over a closed queue, an epic open with every sub-issue closed, worktrees of already-merged branches, open issues missing from the board, `[Unreleased]` waiting for a release. Read + offer only; on a yes the agent performs it through the owning verb (table in step 2b). A repo with nothing to report prints one `sin novedades` line; an unreadable source is listed as `No pude comprobar`, never as clean |
| 3b. Choose the PR shape | (read the offer printed under the pending list) | **Grouped is the default when the issues overlap (#662)**: the listing names each group, the evidence behind it (same repo file named in both issues, or a shared board Area), what it saves in review rounds, and what it held back to keep the PR reviewable (cap 4). One PR per issue is the case that needs a reason — independent risk, or a separate approver |
| 3c. Record the answer | `Board-Work.ps1 -PreferGroupedPRs on\|off\|auto` (or `show` to read the current value and its source without changing anything) | Writes `.agentic-board/config.json` (versioned, like `roles.json`; no GitHub token needed — it is a local decision). `on` = group what overlaps without asking · `off` = one PR per issue, offer suppressed · `auto` = default, propose and let the user decide. `on` never invents a group out of unrelated issues; when nothing overlaps it says so. Ask once, record it — never make the user restate it each session |
| 4b. Start a batch | `Board-Work.ps1 -ProjectNum <n> -StartGroup <n1,n2,...> -Branch` | Same as step 4, for a group chosen at 3b (#633): the first issue gets the branch/worktree, the rest only get the board mechanics (Status/assignee/claim) on that SAME branch, so all of them close through ONE PR/gate/merge |
| 5. Finish it | push branch → PR with `Closes #<num>` (or `New-BoardPR.ps1 -Issue <n1,n2,...>` for a batch — one `Closes #<n>` line per issue) → `Board-ReviewGate.ps1 -Repo <owner/name> -PR <n>` → merge-confirmation summary → user confirms → `Board-Merge.ps1 -PR <n>` only on exit 0 AND confirmation | Review gate (GitHub flow: merge only after approval): requests Copilot review when available, waits for CI checks + review, reports decision/feedback/unresolved threads. **Exit 1 = blocked** → fix, push, re-run. **Exit 2 = nobody reviewed** (#510) → see below. On exit 0, present the mandatory merge-confirmation summary (#630/#631, four parts, above) and WAIT for the user's answer before merging — gate green is a precondition for asking, never a reason to skip asking. Merge via `Board-Merge.ps1` (auto `--admin` when the `pr-before-merge` ruleset marks the PR blocked). Then GitHub fills **Linked pull requests** by itself for every closed issue |

Notes:
- Step 4 supports `-DryRun` (preview, no mutation). A CLOSED issue is refused with a reopen hint.
  It retries once (4s) if the issue was added to the board seconds ago (eventual consistency).
- **Step 4b / batch (#633)**: `-StartGroup` is mutually exclusive with `-Start` and `-Parallel` —
  three different ways to start issues, never combined. If the FIRST (leader) issue can't start
  (blocked, already claimed, etc.) the whole batch aborts untouched; a later issue in the group
  that can't start is just dropped from it with a warning — the rest still share the branch.
- **What splits a group back out (#662)**: an issue that carries risk which should be able to fail
  review on its own, or that a different person should be able to approve or reject separately.
  Those are the reasons — and they are reasons to SPLIT, not conditions to satisfy before daring
  to group. The tool never groups a draft note (there is no issue for a PR to close) or a blocked
  one (`-StartGroup` would drop it anyway), and it never proposes a group on evidence it cannot
  name: if it cannot say WHY two issues belong together, it does not suggest them.
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

  **A reviewer that answers "I could not review this" lands on exit 2 too (#651).** Copilot with no
  quota does not stay silent: it submits a COMMENTED review whose body says it was unable to
  review. That is a review object bound to the current head, so the evidence count accepted it and
  the gate printed `GATE PASSED` naming as reviewer a bot that had just said it never looked. A
  refusal now ends the WAIT (there is no point waiting for a review that is not coming) without
  satisfying the GATE, and the verdict names it instead of printing a bare "0 reviews" that would
  contradict the review list right above it. Scoped to the bot by login **and** body — a human
  review whose prose happens to say "not available" is untouched.
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
  What counts as a citation: only the commit's **subject line** — `(#n)` or a closing keyword
  (`closes|fixes|resolves #n`). A `(#n)` in the body, a bare `#n` and `Refs #n` are
  cross-references and never count. A **revert** (`revert(scope): …` / `Revert "…"`) is not landed
  work: it retires the commits it undoes and a MERGED PR older than it, so a deliberate restart
  of a reverted issue is not refused. When the order of two commits cannot be read (a missing
  date) the refusal is kept.
- **Explicit lock (`-Lock <n>` / `-Unlock <n>`)**: mark an issue owned-elsewhere in ONE step —
  posts the `[abios-claim]` LOCK fingerprint AND moves Status to In Progress — WITHOUT starting or
  branching it locally (needs `-ProjectNum`). Symmetric `-Unlock <n>` posts an UNLOCK claim and
  moves Status back to Backlog. Use it to reserve an issue for another machine/session. `-DryRun`
  previews.
- **Session registry**: every successful `-Start` records `{issue, branch, workPath, sessionPid,
  host, started}` in `.agentic-board/sessions.json` next to the MAIN clone (shared across
  worktrees, gitignored). The pending list shows live local sessions; entries with dead PIDs are
  pruned automatically on read. "Alive" is not just "a process with that PID exists" (#520): the
  process must also have started no later than the entry's `started` stamp, so a recycled PID
  cannot keep a dead session alive. A Windows Terminal (`wt`) session records its OWN tab shell
  (the `pwsh` running `launch-<n>.ps1`), never the launching shell's parent, and an entry whose
  PID is unusable is found again through that launch script (#557).
- **Cross-repo issues (#487).** The fleet used to assume 1 issue = 1 repo = 1 worktree = 1 PR. An issue
  whose work lands in OTHER repositories (README links, licences, CI templates, topics) is now modelled,
  minimally and without touching the single-repo path:
  - **Detection.** The issue carries the `cross-repo` label, or lists its targets in the body under a
    `Target repos:` (or `## Target repos`, `Repos objetivo:`) header - a list of `owner/name`, or the
    slugs inline after the colon. Targets equal to the issue's own repo do not count. A label with no list
    means "cross-repo, read the issue for the targets". Prose is never mined for repos.
  - **Start.** `-Start` / `-Parallel` print a `CROSS-REPO` line and record `crossRepo`, `targetRepos` and
    an empty `prs` list in the session's `sessions.json` row (kept across relaunches).
  - **Briefing.** A launched cross-repo session is told the worktree is its BASE, not the destination: work
    in a clone/worktree of each target repo and open ONE PR per target repo with
    `New-BoardPR.ps1 -Issue <n> -IssueRepo <issue's repo> -Repo <target>` (the body says
    `Refs <issue repo>#<n>`, never `Closes` - a `Closes #<n>` in another repo would close THAT repo's own
    issue), run the review gate on each (`Board-ReviewGate.ps1 -Repo <target> -PR <pr>`, or all at once with `-Issue <n>`), and never close the
    issue itself.
  - **Registry fidelity.** After every PR the session opens: `Board-Work.ps1 -RecordPr <owner/name>#<pr> -ForIssue <n>`
    (local only, no token; refused when the issue has no registered session - it never invents a row). `-Sessions`
    then lists the target repos, every recorded PR with its live state, and "N of M merged".
  - **Gating several PRs (`Board-ReviewGate.ps1 -PullRequests` / `-Issue`).** `-PullRequests 'o/a#5','o/b#9'`
    (or `-Issue <n>`, which takes the PRs recorded for that issue's session) runs the SAME single-PR gate on
    each PR, as its own process with your gate switches forwarded, then prints one verdict per PR and a RUN
    verdict. **All pass = pass (exit 0); any block = block (exit 1); any PR that could not be read or classified,
    or an empty selection, = unknown (exit 4) - never a pass;** a PR that is CI-not-evaluated gives 3 and an
    unreviewed one 2 (ranking, worst first: 1, 4, 3, 2, 0). The aggregation can only escalate: a PR the
    single gate blocks is a block here. `-PR` (the classic call) is unchanged in behaviour and exit codes and
    cannot be mixed with the multi form; `-RecordReview` / `-InstallRuleset` stay one PR at a time. Exit 4 exists
    only in the multi form. Never merge on anything but exit 0, and never merge a PR whose own verdict is not pass.
  - **Closing (explicit, after showing the list).** With `Refs` PRs nothing closes the issue automatically.
    `Board-Work.ps1 -CloseCrossRepo <n>` prints every recorded PR with its live state and closes the issue ONLY
    when ALL of them are MERGED and every target repo the issue declares has a recorded PR; without `-Force` (or
    with `-DryRun`) it closes nothing, so run it once, show the user the list, and re-run with `-Force` after
    their yes. It never closes on the first merged PR, and never when a PR is open, closed unmerged, has no
    readable state, when no PR is recorded, or when the issue has no session (exit 1, nothing closed). An issue
    that is already closed is left alone. `-Sessions` says `LISTO PARA CERRAR` or why not, per session.
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
- **Worktree mode**: when the working copy is busy (dirty tree, another `issue-*` branch, or a
  clean feature branch carrying commits the default branch lacks),
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
| `Board-Work.ps1 -Sessions -Watch [-AutoClean]` | BLOCK polling each session until it finishes (PR MERGED / issue CLOSED / host PID dead), printing progress every `-WatchPollSec` (default 30s) up to `-WatchTimeoutSec` (default 1800s). With `-AutoClean`, tear each finished session down as it completes: kill the tab shell FIRST (the `pwsh -NoExit` left cwd'd in the worktree holds a handle → `git worktree remove` would fail), then `git worktree remove --force` + the branch delete + prune its `sessions.json` entry. The branch delete is merge-safe (#273): a session whose PR **MERGED** is force-deleted as before (the work is on the default branch; local ancestry can't prove this because the flow squash-merges), but one that finished **without** a merged PR (gate blocked, PR closed, agent crashed) is deleted with the safe `git branch -d` — git refuses it, the branch SURVIVES, and the teardown WARNs (in yellow) naming branch + issue instead of destroying the commits silently. Pass `-ForceDeleteBranch` to discard such a branch on purpose. The worktree removal is guarded the same way (#276): an unmerged session whose worktree still holds uncommitted/untracked files is NOT removed — the teardown WARNs with the file count and keeps worktree + branch + registry entry so a later run can retry; `-ForceRemoveWorktree` discards it on purpose. A merged session is torn down as before (its work landed) - EXCEPT a run that was brake-armed (`.agentic-board/brake-armed.json` in its worktree, merge on its contract): a merged PR there is either the human merge after review or the run merging past the brake (#440), and the marker + denial log the evidence would need live in the worktree the teardown deletes, so auto-clean refuses (#518), keeping worktree, branch and registry entry, and names why. Check who merged, then `-ForceRemoveWorktree` proceeds. `scripts/Fleet-Supervisor.ps1 -Check` reports the same situation from the record (marker + PR, with who merged and when) instead of asking the agent to self-report (#517). Also runs after `-Parallel <nums> -Launch/-Fleet -Watch`. `-DryRun` prints the teardown plan without touching git or killing anything (#135) |

- **Only for INDEPENDENT issues.** Never parallelize a chain where one depends on another's
  merge — run those sequentially. The user picks which issues are safe to run together.
- **Each spawned session finishes through step 5** (PR `Closes #<num>` → review gate → merge).
  The briefing is written to `.agentic-board/briefing-<n>.txt` and read by the session, so no
  long prompt ever hits the command line. It names the plugin scripts (PR step, review gate,
  merge, fleet ledger) by a path the session can run in ANY repo: the repo-relative
  `plugins/agentic-board/scripts/…` form when the session's working copy carries the plugin (this
  repo), otherwise the absolute path of the install that composed it. A script that cannot be
  found is listed in a `WARNING` and the session is told to stop and report it — never to replace
  `New-BoardPR.ps1` with a bare `gh pr create` or to skip the review gate (#480).
- **Requires Windows Terminal (`wt`)** for grouped tabs; without it each session opens in its own
  `pwsh` window (still works). Windows-only launcher.
- **Clean up** each worktree after its PR merges: `git worktree remove ../<repo>--issue-<n>`.
- PID tracking is reliable for the `pwsh` fallback; a `wt` launcher forks the terminal host and
  exits, so those entries keep the host session's PID (documented limitation).

