---
description: Administer/automate a GitHub Projects board — verbs work/plan/fill/init/add/move/field/bulk/automate/templates/labels/update/changelog/handoff/doctor/cerrar-ciclo/triage/complete/bi-checklist. Defaults to the CSalcedoDataBI account.
---
You are running the agentic-board /board command.

**If $ARGUMENTS is empty or only whitespace, do NOT run anything yet.** Show this menu and wait
for the user to pick (they can answer with just the number):

```
¿Qué quieres hacer con el board?

1. work             → ver qué issues están pendientes y empezar a trabajar uno (o varios en paralelo)
2. plan             → planificar (o tomar un plan existente) y convertir sus tareas en epic + issues
3. fill --dry-run   → ver qué gaps hay (assignees, Status, Priority, Size, Type) SIN cambiar nada
4. fill --auto      → llenar todos los gaps automáticamente (convierte drafts a issues reales)
5. fill             → llenar gaps pidiendo confirmación antes de ejecutar
6. init             → crear/configurar el board de este repo
7. add <url>        → añadir un issue/PR al board
8. move             → cambiar el Status de un item
9. field            → crear campos o llenar un campo en todos los items por regla
10. bulk            → mover/cerrar/etiquetar muchos items a la vez
11. automate        → instalar CI que sincroniza el board solo
12. templates       → instalar issue forms (bug/feature/task) + PR template en el repo actual
13. labels          → aplicar la taxonomia de labels (bug/docs/refactor/chore/blocked/...) al repo
14. update          → publicar un status update del board (progreso de alto nivel)
15. changelog       → generar un bloque de CHANGELOG (Added/Changed/Fixed) desde los issues Done
16. handoff         → guardar/retomar contexto entre sesiones (save/resume) para continuar días después
17. doctor          → auditar ramas y worktrees locales (mergeadas, estancadas, fantasma) y limpiarlos
18. cerrar-ciclo    → clasificar la RAMA ACTUAL y enrutarla (commitear/PR/gate/merge/limpiar) — cierra la sesión individual
19. triage          → llenar Type/Area/Estimate por evidencia + PROPONER Priority (con confirmación) en los pendientes
20. complete        → verificar que el board quedó full (0 pendientes) — PASS/FAIL, útil para CI o cierre
21. bi-checklist    → mostrar el checklist de release para artefactos BI (modelos/reportes)

── otros comandos (se tipean) ──────────────────────────────────
/scan       → escanear ESTE proyecto por trabajo sin trackear (TODOs, checklists, planes) → issues + plan
/skills     → ciclo de vida de Agent Skills (organize / audit / bootstrap [bi] / freshness)
/knowledge  → registro de referencias externas por dominio (add / harvest / wiki)
/tools      → catálogo unificado de herramientas externas: navegar, investigar e instalar (individual o todas)

── canal de feedback (NO se tipea — se dispara solo) ───────────
abios-feedback → ¿bug o mejora para ESTA herramienta? DILO en lenguaje natural
                 (p.ej. "esto es una mejora para agentic-board") y la skill lo captura
                 como issue SANITIZADO en el repo del tool. No es un comando: no se tipea.
```

If the user picks one of the **otros comandos**, do NOT run a board sub-action — tell them it is a
separate command and to invoke it directly (`/scan`, `/skills`, `/knowledge`, `/tools`); this menu
lists them only so the whole tool is discoverable from one entry point.

`abios-feedback` is DIFFERENT: it is an internal skill, NOT a typeable command — it is never typed
with a slash. It fires on its own when the user describes a bug/improvement for THIS tool (e.g.
"esto es una mejora para agentic-board"). It matters because users assume the plugin has no feedback
channel — it does, and it sanitizes private data before filing to the tool's own public board. If a
user asks to "run" it, invoke the `abios-feedback` skill for them; never tell them to type a slash
command that does not exist.

When they answer with a board option (number or name), execute that sub-action following the
instructions below.

First apply the `gh-account` skill to set `$env:GH_TOKEN` for the right account (default
CSalcedoDataBI; honor an explicit `--account pal-devs` in the arguments). Never run `gh auth switch`.

Then apply the `projects-admin` skill. Parse the request into ONE of these sub-actions and run the
matching recipe from the projects-admin references:

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
        and prints decision + feedback + unresolved threads. Exit 0 = gate passed; exit 1 = blocked.
        Address the printed feedback with new commits, push, and RE-RUN the gate until it
        passes. If the `second-opinion` skill is available, use it as an extra reviewer.
        If no reviewer is available at all, an explicit self-review of `gh pr diff <n>` is
        obligatory before merging — and say so honestly in your report.
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
- **plan** — turn a plan into a tracked epic + native sub-issues on the board. A plan is NOT
  done when a markdown file is written — it is done when its tasks are issues. Two entry modes
  (ask which one if unclear):
  1. **Plan now (interactive):** gather the goal and the SUBSTANTIAL tasks conversationally
     (tiny steps stay as checkboxes in the epic description, not issues). Show the proposed
     epic title + task list and WAIT for the user's approval.
  2. **Plan exists:** read the plan document (or plan-mode output) the user points to, extract
     goal + substantial tasks, show the same proposal, and WAIT for approval. Link the doc in
     the description ONLY as a full `https://github.com/<owner>/<repo>/blob/<branch>/<path>`
     URL on a PUSHED ref — relative paths render broken in issues.
  Then run `scripts/Board-Plan.ps1 -Title "plan: <feature>" -Tasks "A","B",... -Description "..."`
  — it ensures plan/plan-task labels, creates the epic, reuses Board-Breakdown for NATIVE
  Optionally enrich the epic with the four standard items the **`/board expert`** auto-mode
  reads: `-Research "<prior-art / docs found>"`, `-RoleSeed "<expert role objective>"`,
  `-Deliverables "d1","d2"`, `-TestPlan "DoD1","DoD2"` (here `-Description` becomes the Goal).
  Any omitted section renders a `_TBD - fill before /board expert auto_` placeholder, so a plan
  can be created now and completed before running the expert. All four are optional — with none,
  the epic body is rendered exactly as before.
  sub-issues, resolves the repo board with Resolve-Board (never a duplicate), and registers
  epic + children. Suggest `/board fill` for Priority/Size/Type and `/board work` to start the
  first task. Issues are created ONLY in the current repo (origin) — never elsewhere.
- **init** — create a board and fill it coherently: title, short description, README, and link the
  repo (references/board-ops.md). Tell the user the two UI-only items (Default repository pick, View
  name/layout) need one click in settings — do not claim they were set.
- **add** — add an issue/PR to the board (references/issue-ops.md)
- **move** — set an item's Status (references/board-ops.md single-select recipe)
- **field** — two DISTINCT scripts, do not confuse them:
  - **apply a field preset** (`apply en|es`) → `scripts/Apply-FieldPreset.ps1 -ProjectNum <n> -Owner <o> -Lang en`
    (creates the preset's fields + canonical colors; `-Lang`/`-Preset` = `en|es`, NOT `-ApplyPreset`).
  - **bulk-fill ONE custom field across EVERY item by rule** → `scripts/Set-BoardField.ps1` (single-select
    by title-prefix map, or text by `{title}` template — idempotent, retries 502s).
  (references/field-presets.md + board-ops.md). Visibility-per-view and group-by are UI-only — say so.
  - **`apply <lang>` standardizes by DEFAULT.** A board born from GitHub's default template
    (`Todo / In Progress / Done`) is migrated onto the canonical preset with no flag: the legacy
    option is RENAMED in place (by option id → item assignments survive; `Todo`→`Backlog`,
    `P2 Medium`→`P2`, …), never duplicated. A rename hits every item at once, so ALWAYS preview with
    `--dry-run` first and let it confirm (`-Yes` only when already approved); answering `n` skips the
    standardizing and still applies the rest of the preset.
    This was opt-in behind `--migrate` until #300, and that default was the bug: matching options by
    name only, a plain apply added `Backlog` next to `Todo` and left the board in the one state a
    rename cannot repair. `-Migrate` is still accepted as a no-op. `--no-migrate` opts out and does
    NOT create the canonical option beside the legacy one — no path duplicates any more.
  - **`apply <lang> --merge-conflicts`** — for boards ALREADY carrying both (`Todo` *and* `Backlog`):
    moves the legacy option's items onto the canonical one, verifies, then deletes it. Destroys an
    option, so it stays opt-in. Preview with `--dry-run` first.
- **bulk** — batch move/close/label across many items (references/issue-ops.md)
- **fill** — detect and fill ALL gaps across the board by running `scripts/Board-Fill.ps1`
  (pass -Owner, -Repo, -ProjectNum for the current repo's board):
  - The script converts any draft notes to REAL issues in the repo first, then fills gaps:
    Assignees (owner), Status (from issue/PR state), Priority (P2 Medium), Size (M),
    Type (from labels, else Feature).
  - No flags: run with neither -DryRun nor -Auto — the script prints the plan and asks (s/n).
  - `--dry-run`: run with -DryRun — plan only, executes nothing.
  - `--auto`: run with -Auto — fills everything without asking. Use for CI or when already approved.
  - NOTE: Linked PRs and Sub-issues progress are system-derived columns — GitHub sets them
    automatically from PR mentions and sub-issue state. They are NOT writable via API; do not
    attempt to fill them and explain this to the user if asked.
  - NOTE: which columns a VIEW displays is UI-only — if fields look "empty" on the board page,
    tell the user to click `+` at the right of the view header and enable Priority/Size/Type.
- **automate** — install the actions/add-to-project CI workflow (references/automation.md)
- **templates** — install issue forms + PR template into the current repo working copy by running
  `scripts/Install-RepoTemplates.ps1` (default `-Path .`, repo derived from origin):
  - Drops `.github/ISSUE_TEMPLATE/{bug,feature,task,config}.yml` and
    `.github/PULL_REQUEST_TEMPLATE.md` (with the mandatory `Closes #` slot).
  - Ensures the labels the forms reference exist (`bug`/`feature`/`task`) — GitHub silently
    ignores a form label that does not exist.
  - Existing files are SKIPPED (never overwrite a repo's customized templates); `--force`
    overwrites. The script only touches the working copy — commit through the normal flow
    (PR when the work is board-tracked).
- **update** — post a board status update (Projects BP: share high-level progress) by running
  `scripts/Post-BoardStatusUpdate.ps1 -ProjectNum <n>` (auto-generates the body from live counts
  + next pending by Priority; `-Status AT_RISK|OFF_TRACK|COMPLETE` and `-Body` override it).
- **changelog** — generate a Keep-a-Changelog version block from the board's Done issues by
  running `scripts/Board-Changelog.ps1 -ProjectNum <n>`. Groups issues into Added/Changed/Fixed
  by the board Type field (Feature→Added, Bug→Fixed, Docs/Refactor/Chore→Changed; label fallback).
  Includes only issues closed since the last CHANGELOG entry AND not already cited as `(#n)` —
  so shipped work is never double-listed. Prints the block; `-Write` inserts it at the top of
  CHANGELOG.md; `-Version`/`-Date`/`-Since` override the defaults (version read from plugin.json).
  NOTE: the dedup keys on `(#n)` citations, which this tool always emits — pre-existing prose
  entries without a number are not recognized, so review the first generated block before `-Write`.
  For releasing a **BI artifact** (a model/report, not this plugin), the changelog is one step of the
  full release definition-of-done — see `references/bi-release-checklist.md` (M4.1): what the review
  gate enforces (BPA + TMDL-breaking), what stays external to Fabric (deployment, refresh), and what a
  human confirms (renders, rollback).
- **labels** — apply the label taxonomy preset by running `scripts/Apply-LabelPreset.ps1`
  (repo derived from origin, or `-Repo owner/name`). Idempotent `gh label create --force` from
  `presets/labels.json`: `bug`/`docs`/`refactor`/`chore` feed Board-Fill Type detection,
  `blocked` feeds the work dependency check, `roadmap`/`plan`/`plan-task` feed plan tracking.
  Never deletes existing labels.
- **handoff** — save or resume a curated cross-session context, so work can continue in a fresh
  session days later (even on another machine), via `scripts/Board-Handoff.ps1`. Full design in
  `references/handoff.md`. Parse `save` vs `resume` from the request (default: if a
  `[abios-handoff]` comment / local `HANDOFF.md` exists and little was done this session, offer
  **resume**; otherwise **save**).
  - **save** — compose the curated, [V]/[?]-tagged content (next step / done / open threads /
    traps / key files) yourself, verifying each claim live, then run
    `scripts/Board-Handoff.ps1 -Save -NextStep "..." -Done "...","..." -Traps "..." -KeyFiles "..."`.
    It autofills the frontmatter from git + `.agentic-board/sessions.json`, writes a gitignored
    `HANDOFF.md`, archives the previous one, upserts the durable `[abios-handoff]` comment on the
    linked issue, and drops a MEMORY.md pointer (opt-out `-NoMemo`). `-DryRun` previews.
    - **No linked issue?** The durability comes from the issue (the portable `[abios-handoff]`
      comment + the memo). With none resolved (no active session, not on an `issue-<n>` branch),
      `-Save` now **refuses** instead of silently degrading to a gitignored local-only file with no
      memo. OFFER the user the choice: link it with `-Issue <n>` (the next pending is shown by
      `/board work`) — portable + auto-surfaced — or accept a deliberate machine-local handoff with
      `-Local`. Do not just pass `-Local` for them; a local-only handoff is not portable.
  - **resume** — `scripts/Board-Handoff.ps1 -Resume` reads the latest `[abios-handoff]` comment
    (falls back to local `HANDOFF.md`), rehydrates, reports branch/PR drift, carries traps
    forward, clears the consumed pointer, and offers to start the linked issue. TREAT the printed
    handoff as the session briefing and continue that work.
  - **auto-load on resume** (opt-in): `references/handoff-hook.md` wires a SessionStart hook so a
    resumed session surfaces the handoff automatically.
  - **heavy memory** (opt-in, security-gated): for persistent *semantic* memory across projects,
    `scripts/Suggest-HeavyMemory.ps1` proposes installing Basic Memory (upstream, AGPL) — never
    vendored. See `references/heavy-memory.md`. The default remains the lightweight `HANDOFF.md`.
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
- **cerrar-ciclo** (close-the-loop) — classify the CURRENT branch and route it to its next
  disposition by running `scripts/Board-Work.ps1 -CloseLoop` (repo from origin, or `-Repo`). It is
  NOT "merge": merging has the review gate, and "cerrar ciclo" is ambiguous ("ship it" vs "stop for
  today"), so it only ever PROPOSES the next command and performs exactly ONE action — the
  single-session teardown of a proven-merged local branch (the gap the fleet's `-Sessions -Watch
  -AutoClean` never reaches for an interactive session). States it detects on the current branch:
  - **uncommitted changes** → stop; commit or `handoff -Save` (decided BEFORE any PR state, so work is never lost);
  - **commits, no PR** → `New-BoardPR`; **PR open** → `Board-ReviewGate` (merge if it passes, `handoff -Save` if not);
  - **PR merged, branch alive** → the gap: switches to the default branch, `git branch -D` the merged branch
    (squash-merge means `-d` refuses; a proven merge licenses `-D`), and prunes the session-registry entry —
    with confirmation (`-Force` to skip, `-DryRun` to preview). Never on a dirty tree;
  - **PR closed unmerged** → decide: reopen/rescue or discard.
  It operates on the current branch/session only — the repo-wide sweep is `/board doctor`.
  `Board-Merge` now also NOTES when its `--delete-branch` left the local branch behind and points here.
- **triage** — fill an item's triage fields from EVIDENCE and PROPOSE its Priority, via
  `scripts/Board-Triage.ps1` (#306). Not a bulk default — a uniformly-filled board looks prioritised
  without being so; the point is grounded values, not absence of blanks.
  - **`-Pending`** lists the pending items and which of Type/Area/Estimate/Priority are blank — the
    work-list to triage (the board's `Size` equivalent is **Estimate**; there is no Size field).
  - **Type / Area / Estimate are evidence fields.** YOU infer them from the issue's own content — the
    kind of failure (Type), the files/surface it touches (Area), the change size its Scope implies
    (Estimate) — and write them directly: `Board-Triage.ps1 -Issue <n> -Type <t> -Area <a> -Estimate <n>`.
  - **Priority is a business judgement NOT in the repo.** PROPOSE P0–P3 with a one-line rationale per
    issue and let the user confirm in a batch: `-Priority P2 -Rationale '...'` PRINTS the proposal and
    writes nothing; only `-ConfirmPriority` writes it. The script REFUSES `-Priority` with no
    `-Rationale`. Never write Priority silently — a well-argued autonomous guess is still your opinion
    wearing the owner's name.
  - Do this when you START an issue (step 4 below) and when you CREATE issues (`/board plan`), so no
    item lands with an empty Type/Area/Estimate; use `-Pending` to backfill the existing backlog.
- **complete** — verify the board is fully worked (0 PENDING items) by running
  `scripts/Assert-BoardComplete.ps1 -ProjectNum <n> -Owner <o>` (account/board resolved like the other
  sub-actions). "Pending" is the SAME definition `work` lists from (empty Status or a Status meaning
  Backlog, incl. legacy `Todo`); In Progress / In Review / Done / Blocked are NOT pending. Exit 0 =
  board is clear (prints `PASS`); exit 1 = it lists the pending items (`FAIL`). Fails closed on a gh
  error (an unreadable board never reads as "complete"). Use it after a `/board work` sweep to confirm
  the queue is empty, or wire it into CI to assert a milestone board reached zero-pending.
- **bi-checklist** — show the release definition-of-done for a **BI artifact** (a semantic model /
  report / PBIP), by printing `references/bi-release-checklist.md` (M4.1). It is
  a checklist, not a runner: each item is tagged **[tool]** (an agentic-board command enforces it — the
  BPA + TMDL-breaking review gate, `/board changelog`, `/board triage`, `/knowledge`), **[external]** (a
  Fabric/PBI capability the tool references but does not rebuild — deployment pipelines, refresh), or
  **[manual]** (a human judgement — report renders, rollback). Display the file so the user can follow
  it when releasing a model/report; there is nothing to execute.
- Board URL reminder: every response about a board operation — plan,
result, or error — must end with the board URL so the user can open it in one click:
`https://github.com/users/<owner>/projects/<num>` (or `/orgs/<org>/projects/<num>` for org boards).

SAFETY (mandatory, see references/best-practices.md):
- Before init/add/plan, **resolve-or-reuse** the repo's board with `scripts/Resolve-Board.ps1` —
  never create a duplicate board with a blind `gh project create`.
- Before ANY board delete, **always run `scripts/Backup-Board.ps1` first** (JSON snapshot + live
  clone) — unconditionally, without asking. The delete itself still needs explicit confirmation.
- For any destructive action (delete, bulk close/move), print a dry-run of exactly what would
  change and confirm BEFORE mutating.

Arguments: $ARGUMENTS
