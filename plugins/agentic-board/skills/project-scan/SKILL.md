---
name: project-scan
description: Use to scan the CURRENT project for latent, hard-to-track work — code TODO/FIXME, unchecked checklists and "pending/next steps" in docs, and plan/spec docs not yet tracked — then convert the chosen items into issues + a work plan on THIS project's board. Triggers — "escanea el proyecto", "convierte los pendientes en issues", "harvest backlog", "qué hay sin trackear", "arma el plan de trabajo", /scan.
user-invocable: false
---

# project-scan - from latent work to a ready board, in one command

## What it is (and is NOT)
Surfaces work that already exists in the repo but is not tracked, and turns what the user picks into
a standard board with labelled, prioritized, ordered issues and a plan epic. **It targets the CURRENT
project**, the opposite of `abios-feedback` (which targets the tool's own repo).

## Identity and target
1. **Target = the CURRENT repo** (`gh repo view --json nameWithOwner -q .nameWithOwner`). Issues
   are created ONLY there.
2. **Account = that repo's owner**, via [[gh-account]]: personal repo -> `GITHUB_TOKEN_PERSONAL`;
   `PesanteAnalytics` repo -> `--account pal-devs` (`GITHUB_TOKEN_BUSINESS`). A 403 means switch.

## The one script: `scripts/Scan-Project.ps1`

**Plan (default, read-only on GitHub).** Writes only `<repo>/.agentic-board/scan-plan.json`.
- Sources (tracked files only, via `git grep`, so `.gitignore` is honoured):
  - code markers `TODO / FIXME / HACK / XXX / BUG` in the `TAG:` / `TAG(x):` / `TAG ID-1:` form;
  - unchecked `- [ ]` items in Markdown, and bullets under a *pending / next steps / to do / por
    hacer* heading;
  - plan/spec documents (`docs/**/plans`, `specs/`, `.claude/plans`) and any Markdown file with 12+
    open items - each as ONE plan item, because its own checklist tracks its steps.
  - Skipped: `skills/`, `agents/`, `templates/`, `node_modules/`, `vendor/`, `dist/`, `build/`,
    issue/PR templates, `CHANGELOG.md`. Their checklists are content, not work.
- Each item gets a **preset type label** (`bug`, `feature`, `chore`, `docs`, `refactor`, `spike`),
  the labels `Board-Fill` reads, never ad-hoc `type:*` ones. English and Spanish wording are read.
- **Priority with a reason**: P0 for a risk to data, security or uptime; P1 for bugs, plans and
  anything with a date; P2 for features, chores and spikes; P3 for docs and refactors.
- **Dependencies**: "blocked by #12", "depends on #12", "after #12", "waits on #12".
- **Already tracked** items are skipped: an open issue with the same title, or one that cites the
  plan's path. A title found in several files is one item that lists every place.
- **Order**: unblocked first, then Priority, then plans before the rest.
- **PR batches**: unblocked items of the same area (first two folders), at most `-MaxBatch` (4) per
  PR. A blocked item gets its own batch, named after its blocker.

**Apply (`-Apply`, after the user confirms).** For the chosen `-Rows` (default all):
1. `Resolve-Board.ps1`: reuse this repo's board, or create it with the standard fields (Priority,
   Size, Task Type, Area, Estimate, Target; Status with In Review and Blocked). `-BareBoard` opts out.
2. `Apply-LabelPreset.ps1`, plus the `scan` label.
3. One issue per item (labels `scan` + type, `blocked` when it waits on an issue, `plan` for a plan),
   added to the board with its Priority, Status = Blocked when blocked, Task Type = Spike for spikes.
4. A plan epic: every item in order plus the PR batches; each item is a native sub-issue of it.
5. `Board-Fill.ps1 -Auto` fills what is still empty. `-NoFill` skips it.

The plan file records each issue as soon as it exists, so a rerun never creates one twice; it only
refreshes the epic. `-Apply -DryRun` prints the steps and writes nothing.

## How to run it
1. Run the plan. Relay the table in the user's language: row, priority + reason, type, title,
   source, blocked-by; then the PR batches.
2. Ask one question: all rows, some rows, or none. Let the user change a priority or drop a row
   first; edit `scan-plan.json` for that, then apply.
3. Run `-Apply` (with `-Rows` if they chose a subset) and report: board, issues, epic, failures.

## Safety
- Plan first, **one explicit confirmation**, then apply. Never apply on your own initiative.
- Issues only in the resolved current repo; the account follows its owner.
- Issue bodies are factual: source `file:line`, the matching line, the priority reason. Do not paste
  secret-bearing snippets. The same private-content discipline applies if the repo is public.
