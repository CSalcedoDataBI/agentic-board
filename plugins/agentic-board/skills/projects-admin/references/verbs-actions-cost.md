# /board actions-cost — read-only audit of a repo's Actions cost (full recipe)

Loaded on demand by /board (#573, #614).

- **actions-cost** — report what a repo's GitHub Actions setup MEASURABLY costs and where its
  workflow files break the cost rules, by running `scripts/Get-ActionsCostAudit.ps1` (repo derived
  from origin, or `-Repo owner/name`). It is **read-only**: every gh call is a plain GET, it
  writes nothing to the repo, the board or the disk, and it applies no fix. There is no `-Fix`.
  - `-Month yyyy-MM` picks the usage month (default: the current UTC month).
  - By default the workflows are read from the repo's **default branch on GitHub** — the code that
    actually bills. `-Local` (with `-Path`) audits the working tree instead, for a workflow change
    you have not pushed yet. `-Branch` overrides the branch read and the branch whose required
    checks are checked.
  - `-Top N` sizes the account view (default 5); `-Json` emits the whole report for scripting.
  - Needs a token that can read the repo. The usage numbers additionally need the account's own
    billing scope; when GitHub refuses, the cost section says so (see "Not measured" below).
  - Exit code: 0 when the audit ran to the end — findings never fail it, this is a report, not a
    gate; 1 when it could not run at all (repo unreadable, bad `-Month`), which is said out loud and is
    never to be read as "no problems". Expect about one API call per repo that used minutes this
    month (to read its visibility), so an account with many repos takes a minute.

The two halves are kept apart on purpose, because mixing them is how a cost report lies.

## 1. Measured cost — from the usage endpoint, and only from it

Minutes per SKU and per day come from `users/<owner>/settings/billing/usage` (or
`organizations/<org>/...` for an organization repo). Repo visibility comes from `repos/<o>/<r>`.
Two traps are encoded, and both produce a confidently wrong number if you fall into them:

- **`/actions/runs/<id>/timing` is not used.** It returned `total_ms: 0` for every run tried —
  failed, cancelled and successful, on a public and a private repo.
- **Run wall-clock is not cost.** `created_at` → `updated_at` includes queue time. During the
  2026-08-06 Actions incident runs showed 15 minutes of wall-clock and recorded zero executed
  steps: a report built on wall-clock would have claimed ~45 min/attempt of quota that may never
  have been billed. Nothing in this audit is derived from run timestamps.

What is reported: minutes per SKU, minutes per day, storage (GB-hours), gross and billed amount,
and the account view (every repo that used minutes, with its visibility). The **quota-weighted**
figure is the single derived number and is labelled as such: measured minutes × the documented
multiplier (Linux 1, Windows 2, macOS 10). A SKU the audit does not know (a larger runner) is
listed and **not** weighted. Only **private** repos count toward the account's quota total; a repo
whose visibility could not be read is named and excluded, not guessed.

## 2. Rules over `.github/workflows/*.yml`

Every finding names `file:line` and quotes that line. Severity: `ALTA` / `MEDIA` / `BAJA` are
violations; `CONSEJO` is advice; `OBSERVACION` is information only.

| Rule | What it flags | Notes |
|---|---|---|
| R1 | the same job on `pull_request` **and** `push` | two overlaps, told apart because `pull_request.branches` filters the PR **base** and `push.branches` the **pushed** branch: a push to the default branch re-runs the verdict the PR paid for (MEDIA), and a push to a branch a PR can be opened from (a wildcard like `feature/**`: MEDIA; a literal name like `develop`: BAJA) runs next to the PR run. A push that covers every branch (no branch list, only `branches-ignore`, or `**`) double-runs every PR-branch commit (ALTA). A job whose `if:` tests `github.event_name` / `github.ref` is treated as separating the events. Tag-only pushes are not a second run. |
| R2 | no `concurrency` + `cancel-in-progress: true` | judged per unit: the workflow's own `concurrency`, or — when it has none — each job's own, so a job that cancels never hides one that does not (jobs with none are named). Release/deploy workflows (name or file matches release/deploy/publish) are the exception: there it must be `false` — `true` is ALTA, no concurrency is BAJA. The classification is by name and is shown so you can overrule it. |
| R3 | a job without `timeout-minutes` | counts the jobs **in the file**, not the ones a request mentions; a reusable-workflow call is skipped (it takes none); an explicit 360 is flagged (it limits nothing). |
| R4 | `pull_request` workflow with no `paths` / `paths-ignore` | advice only — whether a workflow can be affected by a path is a human call. Carries the deadlock verdict below and the content-site caution (when the `.md` **is** the product it must not be ignored). |
| R5 | `windows-*` (×2) / `macos-*` (×10) on a branch push | `runs-on: ${{ matrix.os }}` is resolved from the matrix (a matrix with `exclude` is reported as not measured, not guessed); tag-only pushes, PR-only workflows and `self-hosted` runners (no GitHub-hosted minutes) are not flagged. |
| R6 | `upload-artifact` without `retention-days`; `setup-*` without a cache | a job with an `actions/cache` step counts as cached; `setup-go` caches by default from v4. |
| R7 | crons that fire more than once a week | the expression is expanded, not pattern-matched, and averaged over the year: `0 9 * * 1-5` is 5 a week, `0 */6 * * *` is 28, and a cron that runs daily but only in January is 0.58 (31 runs a year, fewer than weekly). |
| R8 | a **private** repo | an observation with the measured minutes, never an action: visibility is the owner's call, and whether the content has a reason to be private is not something the audit can measure. |
| FAN | the same install command repeated across the jobs one event starts (`pull_request`; and `push` for workflows that are not also PR workflows, which R1 already covers) | each job is its own runner and checkout; one workflow with jobs, or one job with steps, pays the setup once. Jobs are only grouped when they can run for the same event: workflows whose branch filters cannot overlap (push to `main` vs push to `dev`) are not. A folded `run: >` is one command line, so it is not mistaken for an install. Also reports the runners a PR starts (matrices multiplied out) and whether that count is exact. |
| TRAP | a required status check on a path-filtered workflow | see below. |

### The deadlock trap

`paths-ignore` (or `paths`) plus a **required** status check: a PR that touches only filtered
paths never triggers the workflow, the check never reports, and GitHub parks the PR at "Expected —
waiting for status" forever (the only way out is the admin bypass in the ruleset). So wherever the
audit sees a path filter, or suggests one (R4), it reads the branch's required checks — rulesets
via `rules/branches/<branch>` **and** classic branch protection — matches them to job names
(`name:` or the job id; a matrix appends ` (values)`; a name like `Test ${{ matrix.os }}` is matched by its literal prefix; a job that calls a reusable workflow reports `caller / called`), and says whether the workflow is required. `pull_request_target` counts like `pull_request`. A job whose name has an expression is matched by its literal prefix, which can collide with an unrelated check, so that finding is MEDIA and says so; a name that STARTS with an expression cannot be matched at all, and is reported as not measured.
When the required checks cannot be read completely it says **that** instead of claiming a filter
is safe.

## Nothing is "OK" by omission

- The report ends with a **rule ledger**: per rule, how many things it evaluated / how many
  findings / how many it could not measure. `0 findings of 0 evaluated` reads differently from
  `0 of 12`.
- Section 4 lists everything **not measured**, each with its reason: the usage endpoint refused
  (403/404: the token is not that account's billing reader), the required checks could not be read,
  a runner label or matrix that is an expression, a `cancel-in-progress` expression, a branch
  pattern with negation, a cron the audit cannot expand, a workflow file it could not parse.
- **An unreadable usage endpoint prints "not measured", never 0 minutes.** A measured zero (the
  endpoint answered and the repo used nothing) is a different, valid answer and is printed as one.
- The YAML reader is a small subset parser (no YAML module ships with Windows PowerShell). It
  reads block/flow collections, comments, quoted scalars and block scalars, and **rejects**
  anchors, aliases, tags, tabs, multiple documents and multi-line quoted scalars. A rejected file is
  listed as not measured and none of its rules run — it is never half-audited.

Known limits, so the report is not over-read: composite actions and reusable workflows called from
other repos are not opened; a job's `if` may keep it from starting, so "runners per PR" says when it
is not exact; larger-runner SKUs are listed but not weighted; the plan's included minutes are not
read (the audit reports minutes, not "% of quota").

## Why a new verb and not `/board doctor`

`doctor` audits local git state (branches, worktrees) and its opt-in `-Fix` deletes things; its
subject is refs. This audit's subject is remote CI configuration and it has no write mode at all.
Sharing a verb would put a read-only report behind a command whose contract is "read-only unless
`-Fix`", and would make `doctor`'s output answer two unrelated questions.

## Out of scope

- Applying any fix — this is a report. Fixing the findings is ordinary work on the workflow files.
- Changing how many branches or PRs a work session creates; that is not the cost driver — runners
  per PR and the setup each repeats are.
- Changing repo visibility. R8 reports the fact and stops.
