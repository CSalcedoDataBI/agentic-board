---
name: projects-admin
description: Use to administer or automate a GitHub Projects (v2) board or its issues — create/configure a project, set Status/Priority/Target fields, add/move/bulk-edit items, link a board to a repo, install CI auto-add, run /board fill to detect and fix gaps, or /board work to see pending issues across boards and start one. Always resolves identity via gh-account (default CSalcedoDataBI). Triggers — "administra el board", "mueve a Done", "crea el project", "add to board", "bulk close", "automatiza el board", "llena el board", "qué hay pendiente", "qué issue trabajo", "empecemos un issue", /board.
user-invocable: false
---

# projects-admin — GitHub Projects (v2) Board & Issue Admin

This skill covers the full lifecycle of a GitHub Projects v2 board and its items: creation, field setup, issue management, bulk operations, CI automation, and gap detection/fill via `/board fill`.

> **Diagrams in any artifact** (plan/epic/issue body, handoff, status update): never hand-draw
> ASCII art — use the `diagram-authoring` skill (Mermaid by default, escalate to D2/Graphviz via
> Kroki). See `skills/diagram-authoring/SKILL.md`.

---

## Step 0 — Identity (always first)

**Before every operation in this skill, apply the `gh-account` skill** to load `GH_TOKEN` for the correct account. The default account is **CSalcedoDataBI**; switch to PAL-Devs only when the user explicitly says so or when you receive a 403 on a PAL-owned board.

```powershell
# Default — CSalcedoDataBI
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL', 'User')
$env:GH_TOKEN = $t
```

Every `gh project` and `gh issue` command below assumes `$env:GH_TOKEN` is already set for the correct account. Never run `gh auth switch` — it mutates global `gh` state.

---

## Anchoring: one board, one repo

A board must be linked to exactly one origin repo before issue operations begin.

```powershell
# Resolve the origin repo (run inside the repo's working directory)
$origin = gh repo view --json nameWithOwner -q .nameWithOwner
# e.g. "CSalcedoDataBI/agentic-board"
```

Link or verify the link:

```powershell
gh project link <num> --owner <owner> --repo $origin
```

**Hard rule:** create issues ONLY in the `origin` owner/repo resolved above. Never write issues to a random shared board or unrelated repo.

**Hard rule — a board only holds items from its own repo.** Before `item-add`, the item's source
repo MUST equal the board's anchored repo. A board is about ONE project; never mix in issues from a
different (e.g. private) project. Verify and refuse otherwise:
```powershell
# the URL you are about to add must belong to the board's anchored repo
$anchored = "<owner>/<repo>"                      # the repo this board is linked to
if ($url -notmatch [regex]::Escape("github.com/$anchored/")) {
  throw "Refusing: $url is not from $anchored. Add it to that project's OWN board instead."
}
gh project item-add <num> --owner <owner> --url $url
```
This keeps a public tool's board free of any private-project content (and vice versa).

---

## Field conventions

All boards in this ecosystem use three single-select fields with these exact names:

| Field | Purpose | Typical options |
|-------|---------|----------------|
| **Status** | Workflow stage (kanban column) | `Backlog`, `In Progress`, `In Review`, `Blocked`, `Done` |
| **Priority** | Urgency / triage | `P0`, `P1`, `P2`, `P3` |
| **Target** | Milestone / sprint target | Sprint labels or date strings |

For the exact commands to create these fields and set their values on items, see `references/board-ops.md`.

---

## /board fill — Detect and fill column gaps

Scans the board for missing values (assignees, Status) and fills them. In CI it runs `scripts/board-sync.sh`; in interactive sessions it runs the PowerShell sequence below.

| Variant | Behavior |
|---------|----------|
| `/board fill` | Shows a full plan and asks for confirmation before acting |
| `/board fill --dry-run` | Prints what would change, executes nothing |
| `/board fill --auto` | Fills without asking — for CI or when the user has already approved |

### What gets filled

| Column | Fill rule |
|--------|-----------|
| **Assignees** | If empty, assign the board owner (`$OWNER`) |
| **Status** | Issue closed → `Done`; PR merged → `Done`; open PR → `In Review`; else → `Backlog` |
| **Linked PRs** | System-derived by GitHub from PR mentions — not writable via API |
| **Sub-issues progress** | System-derived from closed sub-issues — not writable via API |

### Interactive mode (Claude Code session)

```powershell
# 1. Load token
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL', 'User'); $env:GH_TOKEN = $t

# 2. Read all board items via GraphQL
$proj = gh api graphql -f query='
query($owner:String!, $num:Int!) {
  user(login:$owner) {
    projectV2(number:$num) {
      id
      items(first:100) {
        nodes {
          id
          fieldValues(first:20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2SingleSelectField { name } } optionId }
            }
          }
          content {
            ... on Issue { number state title assignees(first:5) { nodes { login } } }
          }
        }
      }
      fields(first:30) {
        nodes { ... on ProjectV2SingleSelectField { id name options { id name } } }
      }
    }
  }
}' -F owner=<owner> -F num=<project-num>

# 3. Detect gaps — items missing assignee or Status
# 4. --dry-run: print plan
# 5. --auto or after confirmation: execute
#    a) Empty assignee
gh issue edit <issue-num> --repo <owner>/<repo> --add-assignee <owner>
#    b) Wrong / missing Status
gh api graphql -f query='mutation(...) { updateProjectV2ItemFieldValue(...) { projectV2Item { id } } }' ...
```

### CI mode (GitHub Actions)

The workflow `.github/workflows/board-sync.yml` runs `bash scripts/board-sync.sh` automatically on every issue or PR event. This is equivalent to `/board fill --auto` with no manual intervention.

Triggers already configured:
```yaml
on:
  issues:    [opened, closed, reopened, assigned]
  pull_request: [opened, closed]
  schedule:  # Monday 9am UTC — weekly health check
  workflow_dispatch:
```

---

## /board work — See pending work and start an issue

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

---

## /board doctor

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

---

## Routing table

| Intent | Reference file | Command family |
|--------|---------------|----------------|
| Get the repo's board (reuse, don't duplicate) | `references/best-practices.md` | `Resolve-Board.ps1` (use BEFORE create) |
| Create a new project board (only if none) | `references/board-ops.md` | via `Resolve-Board.ps1` → `gh project create` |
| Delete a board (backup first, always) | `references/best-practices.md` | `Backup-Board.ps1` → `gh project delete` |
| Link board to a repo | `references/board-ops.md` | `gh project link` |
| Create / list fields (Status, Priority, Target) | `references/board-ops.md` | `gh project field-create`, `gh project field-list` |
| Apply a whole field preset (EN/ES, custom values) | `references/field-presets.md` | `Apply-FieldPreset.ps1 -Lang en\|es` |
| **Standardize an EXISTING board onto the preset** (renames `Todo`→`Backlog` in place, keeps assignments) | `references/field-presets.md` | `Apply-FieldPreset.ps1` — default since #300 (preview with `-DryRun`, opt out with `-NoMigrate`) |
| Board that ALREADY has both `Todo` and `Backlog` (moves items, then deletes the legacy option) | `references/field-presets.md` | `Apply-FieldPreset.ps1 -MergeConflicts` (preview with `-DryRun`) |
| Set a field value on an item | `references/board-ops.md` | `gh project item-edit` |
| Bulk-fill a custom field across ALL items (by rule) | `references/board-ops.md` | `scripts/Set-BoardField.ps1` |
| **Detect and fill board gaps** | **this file — `/board fill` section** | **`/board fill` / `--dry-run` / `--auto`** |
| **See pending work / start an issue** | **this file — `/board work` section** | **`Board-Work.ps1 -ListBoards` / `-ProjectNum` / `-Start`** |
| Manage views / inspect board | `references/board-ops.md` | `gh project view`, `gh project item-list` |
| Create an issue with a label | `references/issue-ops.md` | `gh issue create` |
| Create / ensure a label exists | `references/issue-ops.md` | `gh label create --force` |
| Add an existing issue/PR to the board | `references/issue-ops.md` | `gh project item-add` |
| Create a native sub-issue (parent→child) | `references/issue-ops.md` | `github-business sub_issue_write` (MCP) |
| Place a full GitHub URL link in issue body | `references/issue-ops.md` | inline in `--body` |
| Move an item's Status field | `references/issue-ops.md` + `references/board-ops.md` | `gh project item-edit` (single-select set) |
| Bulk move items to a status | `references/issue-ops.md` + `references/board-ops.md` | loop over `item-list` → `item-edit` |
| Bulk close issues | `references/issue-ops.md` | loop over `gh issue list` → `gh issue close` |
| Bulk label issues | `references/issue-ops.md` | loop over issues → `gh issue edit --add-label` |
| Install CI auto-add workflow | `references/automation.md` | drop-in YAML |
| Install issue forms + PR template | `Install-RepoTemplates.ps1` | copies `presets/templates/` into `.github/`, ensures form labels exist, never overwrites without `-Force` |
| Apply the label taxonomy | `Apply-LabelPreset.ps1` | idempotent `gh label create --force` from `presets/labels.json`; type labels feed Board-Fill, `blocked` feeds work; never deletes |
| Break a big issue into sub-issues | `Board-Breakdown.ps1 -Parent <n> -Tasks ...` | native sub-issues via `addSubIssue`; refuses a CLOSED parent; task-list checkboxes are the fallback for tiny pieces |
| Post a board status update | `Post-BoardStatusUpdate.ps1 -ProjectNum <n>` | `createProjectV2StatusUpdate`; body auto-generated from live counts + next pending, or `-Body`/`-Status` override |
| Turn a plan into epic + sub-issues | `Board-Plan.ps1 -Title "plan: X" -Tasks ...` | ensures plan labels, creates epic, reuses Board-Breakdown (native sub-issues), Resolve-Board (no duplicates), registers all on the board; doc links must be full blob URLs on pushed refs |
| **Audit stale / unmerged / ghost branches and worktrees** | **this file — `/board doctor` section** | **`Board-Doctor.ps1`** (read-only; `-Fix` confirms per branch) |
| **Verify the board is fully worked** (0 pending) — `/board complete` | this file | `Assert-BoardComplete.ps1 -ProjectNum <n> -Owner <o>` (exit 0 = PASS/clear, exit 1 lists pending; CI-friendly) |
| Release a **BI artifact** (model/report) — the definition of done — `/board bi-checklist` | `references/bi-release-checklist.md` | the M4.1 spec: what the gate enforces (BPA + TMDL-breaking), what stays external to Fabric (deploy/refresh), what a human confirms |

---

## Safe operations — MANDATORY (see `references/best-practices.md`)

These two rules are not optional and must be followed every time:

### 1. Resolve-or-reuse before creating a board (never duplicate)
Before `init`, `add`, or registering a plan, **resolve the existing board** instead of blindly
creating one — duplicate boards are the most common mistake:
```powershell
$num = & "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-Board.ps1" -Owner <owner> -Repo <owner>/<repo>
# reuses the repo's board (canonical title "<repo> — Roadmap" or one containing the repo name),
# creating + linking + describing only if none exists. NEVER call `gh project create` directly.
```

### 2. Always back up before deleting (unconditional, do NOT ask)
Any `gh project delete` MUST be preceded by a full backup — automatically, without asking:
```powershell
& "${CLAUDE_PLUGIN_ROOT}/scripts/Backup-Board.ps1" -Number <num> -Owner <owner>
# writes a JSON snapshot (project+fields+items) AND a restorable live clone, THEN you may delete.
```
The backup happens unconditionally; the **delete** itself still needs explicit user confirmation.

## Safety — destructive operations require dry-run + confirmation

Before running any operation that mutates more than one item (bulk move, bulk close, bulk label, project delete), you MUST:

1. **Print the plan**: list every item that would be affected (title, number, current state).
2. **Pause and ask the user** to confirm before proceeding (the backup in rule 2 above already ran).
3. Only after explicit confirmation, run the mutation.

Example pattern for bulk close:

```powershell
# Step 1 — dry run: show what would close
$issues = gh issue list --repo $origin --state open --label board --json number,title | ConvertFrom-Json
$issues | ForEach-Object { Write-Host "Would close #$($_.number): $($_.title)" }

# Step 2 — confirm
# Ask user: "Ready to close these N issues? (yes/no)"

# Step 3 — execute only after "yes"
$issues | ForEach-Object { gh issue close $_.number --repo $origin }
```

The same dry-run pattern applies to `gh project delete` and any bulk `item-edit` loop.

---

## Relation to plan-tracking

This skill does **NOT** reimplement the `plan-tracking` skill. `plan-tracking` handles the workflow of turning a written plan document into a tracked GitHub epic with child issues (plan→epic). The present skill is general board administration — field setup, item moves, issue CRUD, CI automation — and can be used independently of any plan.

If you need to turn a plan into an epic, invoke the `plan-tracking` skill. If you need to move items on a board or configure project fields after that, use this skill.

---

## Verification checklist

Before reporting a board operation as complete, confirm:

- Account pinned and `project` scope verified? (`gh-account` step 0 done)
- Board linked to THIS repo, not to a random or shared board?
- Any links placed in issue bodies or project descriptions are full `https://github.com/<owner>/<repo>/blob/<branch>/...` URLs (never relative paths)?
- Added items are visible on the board after `gh project item-add` (spot-check with `gh project item-list`)?
- Dry-run was shown to the user and confirmed before any destructive op?
- **Resolve-or-reuse was used (no new duplicate board created)?**
- **A backup ran (JSON + live clone) BEFORE any `gh project delete`?**
