---
description: Run a GitHub Projects board — verbs work/plan/fill/init/add/move/field/bulk/automate/templates/labels/update/changelog/handoff/doctor/close-cycle/telemetry/triage/complete/bi-checklist/actions-cost/setup. No arguments shows the menu.
---
You are running the agentic-board /board command.

**If $ARGUMENTS is empty or only whitespace, do NOT start any work yet.** The one thing you run
first is the read-only `scripts/Board-Work.ps1 -PreferGroupedPRs show` (no GitHub token, writes no
preference): its first line is `Grouped PRs: <value> (<source>)`. Put that text in the sub-line under
`1. work` below, in place of `<repo value>` (#681). If it fails or the cwd is not a git repo,
print `auto (default)`. Then show this menu and wait for the user to pick (they can answer with
just the number).

Show this menu translated into the user's language (keep the verbs, flags, command names and
numbers exactly as written; translate only the descriptions and headings):

```
What do you want to do with the board?

1. work             → see which issues are pending and start working (related ones go together in a single PR)
                      Grouped PRs in this repo: <repo value> — change with: work -PreferGroupedPRs on|off|auto
2. plan             → plan (or take an existing plan) and turn its tasks into an epic + issues
3. fill --dry-run   → see which gaps exist (assignees, Status, Priority, Size, Type) WITHOUT changing anything
4. fill --auto      → fill every gap automatically (converts drafts into real issues)
5. fill             → fill gaps, asking for confirmation before executing
6. init             → create/configure this repo's board
7. add <url>        → add an issue/PR to the board
8. move             → change an item's Status
9. field            → create fields or fill one field on every item by rule
10. bulk            → move/close/label many items at once
11. automate        → install CI that keeps the board in sync by itself
12. templates       → install issue forms (bug/feature/task) + PR template in the current repo
13. labels          → apply the label taxonomy (bug/docs/refactor/chore/blocked/...) to the repo
14. update          → post a board status update (high-level progress)
15. changelog       → generate a CHANGELOG block (Added/Changed/Fixed) from the Done issues
16. handoff         → save/resume context between sessions (save/resume) to continue days later
17. doctor          → audit local branches and worktrees (merged, stale, phantom) and clean them up
18. close-cycle     → classify the CURRENT BRANCH and route it (commit/PR/gate/merge/clean up) — closes the individual session
19. telemetry       → measure how the tool behaved in your real sessions (incremental sweep)
20. triage          → fill Type/Area/Estimate from evidence + PROPOSE Priority (with confirmation) on pending items
21. complete        → verify the board is fully worked (0 pending) — PASS/FAIL, useful for CI or wrap-up
22. bi-checklist    → show the release checklist for BI artifacts (models/reports)
23. actions-cost    → audit this repo's GitHub Actions cost (read-only): MEASURED minutes + cost rules over the workflows
24. setup           → set up your accounts: default owner, which env var holds each account's token, the agent identity

── other commands (typed) ──────────────────────────────────────
/scan       → scan THIS project for untracked work (TODOs, checklists, plans) → issues + plan
/skills     → Agent Skills lifecycle (organize / audit / bootstrap [bi] / freshness)
/knowledge  → registry of external references by domain (add / harvest / wiki)
/tools      → unified catalog of external tools: browse, research and install (one or all)
/expert     → auto-expert: takes a plan and runs it ON ITS OWN (config = define the contract, auto = run autonomously)
/cleanup    → machine housekeeping: sessions, transcripts, disk and plugins (not board work)

── feedback channel (NOT typed — it fires on its own) ──────────
abios-feedback → bug or improvement for THIS tool? SAY IT in natural language
                 (e.g. "this is an improvement for agentic-board") and the skill captures it
                 as a SANITIZED issue in the tool's repo. It is not a command: it is not typed.
```

If the user picks one of the **other commands**, do NOT run a board sub-action — tell them it is a
separate command and to invoke it directly (`/scan`, `/skills`, `/knowledge`, `/tools`, `/cleanup`); this menu
lists them only so the whole tool is discoverable from one entry point.

`abios-feedback` is DIFFERENT: it is an internal skill, NOT a typeable command — it is never typed
with a slash. It fires on its own when the user describes a bug/improvement for THIS tool (e.g.
"this is an improvement for agentic-board", or in Spanish "esto es una mejora para agentic-board").
It matters because users assume the plugin has no feedback
channel — it does, and it sanitizes private data before filing to the tool's own public board. If a
user asks to "run" it, invoke the `abios-feedback` skill for them; never tell them to type a slash
command that does not exist.

When they answer with a board option (number or name), execute that sub-action.

First apply the `gh-account` skill to set `$env:GH_TOKEN` for the right account (the default
owner of your account map; honor an explicit `--account <alias>` in the arguments). Never run
`gh auth switch`. `setup` is the exception: it needs no token.

Then apply the `projects-admin` skill and route the request to ONE sub-action. **The big verbs
load their full contract on demand (#573)** — for each of these, READ the named reference file
from the projects-admin skill's `references/` directory NOW and follow it exactly; do not
improvise the recipe from this summary:

- **work** — the daily driver: pending work → start an issue → PR + review gate + merge
  (single or `-Parallel`/`-Launch` fleet). The pending list also offers the issues that would
  sensibly share ONE PR, with the evidence behind each group and what that saves in review
  rounds — grouped is the default posture when they overlap (#662), and the repo can record its
  standing answer with `-PreferGroupedPRs on|off|auto` (`show` reads the current value and where it
  came from; the menu above prints it). Full contract: `references/verbs-work.md`.
- **plan** — turn a plan into a tracked epic + native sub-issues (interactive or from a doc),
  with the enriched sections `/board expert auto` reads. Full contract: `references/verbs-plan.md`.
- **fill** — detect and fill ALL board gaps (drafts→issues, assignees, Status, Priority, Size,
  Type), with `--dry-run` / `--auto` variants. Full contract: `references/verbs-fill.md`.
- **field** — two DISTINCT scripts (apply a preset vs bulk-fill one field by rule), including
  the default standardize-in-place migration. Full contract: `references/verbs-field.md`.
- **changelog** — generate the Keep-a-Changelog block from Done issues (dedup on `(#n)`
  citations; review before `-Write`). Full contract: `references/verbs-changelog.md`.
- **handoff** — save/resume curated cross-session context (`[abios-handoff]` comment + local
  file; refusal rules when no issue is linked), or `-Recover` a session that ended without saving
  from its local transcript (same machine only). Full contract: `references/verbs-handoff.md`.
- **doctor** — audit local branches/worktrees against git reality (never `git branch --merged`
  here: this repo squash-merges). Full contract: `references/verbs-doctor.md`.
- **close-cycle** — classify the CURRENT branch and route it (commit/PR/gate/merge/teardown);
  performs exactly ONE action. Full contract: `references/verbs-close-cycle.md`. The old Spanish
  name `cerrar-ciclo` is a deprecated alias (#733): accept it, run `close-cycle`, and tell the user
  the new name in one line. It will be removed in a later release.
- **telemetry** — the incremental field sweep over real session transcripts (watermarks, four
  mechanical signals, read-only). Full contract: `references/verbs-telemetry.md`.
- **triage** — fill Type/Area/Estimate from evidence and PROPOSE Priority (never write it
  silently). Full contract: `references/verbs-triage.md`.
- **actions-cost** — READ-ONLY audit of a repo's GitHub Actions cost: minutes MEASURED from the account
  usage endpoint (never the runs timing endpoint or run wall-clock), plus the cost rules over its
  `.github/workflows` (timeouts, concurrency, duplicate triggers, runners, crons, retention, repeated
  setup, the required-check deadlock trap). Every finding carries file:line; whatever it cannot measure is
  listed with the reason, never reported as clean. Writes nothing and has no fix mode. Full contract:
  `references/verbs-actions-cost.md`.

**Machine housekeeping is not board work — it moved to `/cleanup` (a separate command).** For one
release these old spellings still work: route them to the cleanup-ops engine (read `${CLAUDE_PLUGIN_ROOT}/skills/cleanup-ops/SKILL.md`), run the `/cleanup`
equivalent, and tell the user the new command in one line:
`/board plugins [sessions|clean]` → `/cleanup plugins [sessions|clean]`;
`/board close-cycle --all [-Scope …]` → `/cleanup sessions [-Scope …]`.

The short verbs run directly:

- **init** — create a board and fill it coherently: title, short description, README, and link the
  repo (references/board-ops.md). Tell the user the two UI-only items (Default repository pick, View
  name/layout) need one click in settings — do not claim they were set.
- **add** — add an issue/PR to the board (references/issue-ops.md)
- **move** — set an item's Status (references/board-ops.md single-select recipe)
- **bulk** — batch move/close/label across many items (references/issue-ops.md)
- **automate** — install the actions/add-to-project CI workflow (references/automation.md)
- **templates** — install issue forms + PR template into the current repo working copy by running
  `scripts/Install-RepoTemplates.ps1` (default `-Path .`, repo derived from origin). Existing
  files are SKIPPED (never overwrite customized templates); `--force` overwrites. Ensures the
  labels the forms reference exist. Only touches the working copy.
- **update** — post a board status update (Projects BP: share high-level progress) by running
  `scripts/Post-BoardStatusUpdate.ps1 -ProjectNum <n>` (auto-generates the body from live counts
  + next pending by Priority; `-Status AT_RISK|OFF_TRACK|COMPLETE` and `-Body` override it).
- **labels** — apply the label taxonomy preset by running `scripts/Apply-LabelPreset.ps1`
  (repo derived from origin, or `-Repo owner/name`). Idempotent; never deletes existing labels.
- **complete** — verify the board is fully worked (0 PENDING items) by running
  `scripts/Assert-BoardComplete.ps1 -ProjectNum <n> -Owner <o>`. "Pending" is the same definition
  `work` lists from. Exit 0 = PASS/clear; exit 1 lists the pending items. Fails closed on a gh
  error (an unreadable board never reads as "complete").
- **setup** — write or show the user's account map (`~/.agentic-board/accounts.json`, #762) by
  running `scripts/Set-AbiosAccounts.ps1`. Start with `-Show`. Then ASK, one at a time: the
  default board owner (offer the login `gh api user --jq .login` returns); for each account they
  use, the env var that holds its token (`-Map 'login=VAR'`; an env var NAME, never the token
  itself — never ask for or echo a token); optional short aliases (`-Alias 'alias=login'`); and,
  only if they run autonomous `/expert` sessions, the variable of a separate machine identity
  (`-AgentTokenVar`). Preview with `-DryRun`, write on their confirmation, then `-Show` again.
  With no map at all the plugin uses `GH_TOKEN`, then `gh auth token` — say so: a single-account
  user can skip setup.
- **bi-checklist** — show the release definition-of-done for a **BI artifact** by printing
  `references/bi-release-checklist.md` (M4.1). It is a checklist, not a runner: items are tagged
  **[tool]** / **[external]** / **[manual]**. Display the file; there is nothing to execute.

Board URL reminder: every response about a board operation — plan, result, or error — must end
with the board URL so the user can open it in one click:
`https://github.com/users/<owner>/projects/<num>` (or `/orgs/<org>/projects/<num>` for org boards).

SAFETY (mandatory, see references/best-practices.md):
- Before init/add/plan, **resolve-or-reuse** the repo's board with `scripts/Resolve-Board.ps1` —
  never create a duplicate board with a blind `gh project create`.
- Before ANY board delete, **always run `scripts/Backup-Board.ps1` first** (JSON snapshot + live
  clone) — unconditionally, without asking. The delete itself still needs explicit confirmation.
- For any destructive action (delete, bulk close/move), print a dry-run of exactly what would
  change and confirm BEFORE mutating.

<!-- BEGIN:closing-summary - generated by Update-Docs.ps1 from the renderer; do not edit -->
**Closing summary — required (#491).** End your reply to the user with these four blocks,
in this order, with these headings. Never drop one: when a block has nothing in it,
write its when-empty sentence instead. A silent block is indistinguishable from an answer
that got cut off, which is the failure this contract exists to remove.

| # | Heading | When there is nothing to say |
|---|---|---|
| 1 | **What I found** | Nothing unexpected. |
| 2 | **What I did** | Nothing - nothing was changed. |
| 3 | **What is left** | Nothing - no open work. |
| 4 | **What I need from you** | Nothing - this is done. |

The headings and sentences above are the English reference. Always write them in the
language the user is speaking - translate the headings too (a user writing in Spanish gets
Spanish headings) - keeping the same four blocks in the same order, in words a BI
professional can act on.
This block is generated from the shared renderer — to change the wording, change the
renderer, not this text.
<!-- END:closing-summary -->

Arguments: $ARGUMENTS
