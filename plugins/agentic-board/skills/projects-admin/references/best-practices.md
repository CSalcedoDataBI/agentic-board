# best-practices — safe operations & methodology

The conventions this tool enforces, and the methodology they come from. Grounded in GitHub's own
Projects guidance and standard agile practice (not invented here).

## Methodology: is this Scrum?
No — GitHub Projects is fundamentally a **Kanban** tool: the `Status` field (Backlog / In Progress /
In Review / Done) is a Kanban flow. GitHub has **no first-class backlog or story points**; Scrum
elements are layered on with custom fields/labels. The pragmatic, widely-recommended model is a
**hybrid Kanban + Scrum ("Scrumban")**:

| Element | Practice | In this tool |
|---|---|---|
| Flow / WIP | Kanban Status columns | `Status` field (preset) |
| Estimation (story points) | not native — use a field | `Estimate` (NUMBER) |
| Sprints / iterations | not native — use a field | `Target` (text or iteration) |
| Work type triage | labels / field | `Type` (Bug/Feature/…) |
| Priority | field | `Priority` (P0–P3) |
| Standardized issues | issue templates | factual issue bodies (file:line + evidence) |
| Traceability | task id in commits, link issues | sub-issues for epics, full blob URLs |

See sources at the bottom.

## Safe-operations rules (enforced, not optional)
1. **Never create a duplicate board.** Before `init`/`add`/plan, **resolve-or-reuse** the repo's
   board with `Resolve-Board.ps1` (matches the canonical title `<repo> — Roadmap` or any board whose
   title contains the repo name, excluding backups). Create only if none exists. Direct
   `gh project create` without resolving first is a **bug** — do not do it.
2. **Always back up before deleting.** Any `gh project delete` MUST be preceded by
   `Backup-Board.ps1` (JSON snapshot of project+fields+items **and** a restorable live clone). This
   backup is **unconditional and not asked for** — it just happens. The delete itself still needs the
   user's explicit confirmation (destructive).
3. **One board ⇄ one repo** (anchoring): `gh project link`. Issues go only to the resolved origin repo.
   Before `item-add`, the item's source repo MUST equal the board's anchored repo — refuse to add an
   issue from a different (e.g. private) project. A public tool's board stays 100% about that tool;
   private-project work belongs on that project's OWN board.
4. **Dry-run + confirm** for any bulk/destructive change; show exactly what will change first.
5. **Idempotency:** labels/fields use `--force`/skip-if-exists; re-running a command must not duplicate.
6. **Visibility matches exposure:** boards are Private by default; a board linked from a **public**
   repo's docs/showcase must be set **Public** (`gh project edit --visibility PUBLIC`) so the links
   work for everyone. Never silently make a private repo's board public.
7. **Scope local test runs to what changed — the full suite is the exception, not the default.**
   (#630/#632) Before running Pester, identify the test file(s) matching the changed script(s)
   (e.g. touching `Board-ReviewGate.ps1` → run `Board-ReviewGate.Tests.ps1`) and run only those,
   saying out loud which ones and why. Escalate to the FULL suite only when: the changed file is
   shared/foundational (imported across many scripts — `Invoke-Gh.ps1` is the canonical example),
   or this is the PR that closes out an epic (one full run for integration confidence before the
   epic is done, not one per sub-issue). State the escalation reason before running it — a silent
   multi-hundred-test run reads as thoroughness but is really just cost the user did not ask for.

## Standard field set (preset)
`Status · Priority · Type · Area · Estimate · Target` (EN) — the Scrumban-minimal governance set.
Apply with `Apply-FieldPreset.ps1` (EN/ES). See `field-presets.md`.

## Sources
- [Planning and tracking with Projects — GitHub Docs](https://docs.github.com/en/issues/planning-and-tracking-with-projects)
- [GitHub Issues — project planning](https://github.com/features/issues)
- [Rules to Better Scrum using GitHub — SSW](https://www.ssw.com.au/rules/rules-to-better-scrum-using-github)
- [Sprint Planning with GitHub issues — Codetree](https://codetree.com/guides/sprint-planning-github-issues)
