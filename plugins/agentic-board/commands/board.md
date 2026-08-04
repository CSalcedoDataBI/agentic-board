---
description: Administer/automate a GitHub Projects board — verbs work/plan/fill/init/add/move/field/bulk/automate/templates/labels/update/changelog/handoff/doctor/cerrar-ciclo/telemetry/triage/complete/bi-checklist. Defaults to the CSalcedoDataBI account.
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
19. telemetry       → medir cómo se comportó la herramienta en tus sesiones reales (barrido incremental)
20. triage          → llenar Type/Area/Estimate por evidencia + PROPONER Priority (con confirmación) en los pendientes
21. complete        → verificar que el board quedó full (0 pendientes) — PASS/FAIL, útil para CI o cierre
22. bi-checklist    → mostrar el checklist de release para artefactos BI (modelos/reportes)

── otros comandos (se tipean) ──────────────────────────────────
/scan       → escanear ESTE proyecto por trabajo sin trackear (TODOs, checklists, planes) → issues + plan
/skills     → ciclo de vida de Agent Skills (organize / audit / bootstrap [bi] / freshness)
/knowledge  → registro de referencias externas por dominio (add / harvest / wiki)
/tools      → catálogo unificado de herramientas externas: navegar, investigar e instalar (individual o todas)
/expert     → auto-experto: toma un plan y lo ejecuta SOLO (config = define el contrato, auto = corre autónomo)

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

When they answer with a board option (number or name), execute that sub-action.

First apply the `gh-account` skill to set `$env:GH_TOKEN` for the right account (default
CSalcedoDataBI; honor an explicit `--account pal-devs` in the arguments). Never run `gh auth switch`.

Then apply the `projects-admin` skill and route the request to ONE sub-action. **The big verbs
load their full contract on demand (#573)** — for each of these, READ the named reference file
from the projects-admin skill's `references/` directory NOW and follow it exactly; do not
improvise the recipe from this summary:

- **work** — the daily driver: pending work → start an issue → PR + review gate + merge
  (single or `-Parallel`/`-Launch` fleet). Full contract: `references/verbs-work.md`.
- **plan** — turn a plan into a tracked epic + native sub-issues (interactive or from a doc),
  with the enriched sections `/board expert auto` reads. Full contract: `references/verbs-plan.md`.
- **fill** — detect and fill ALL board gaps (drafts→issues, assignees, Status, Priority, Size,
  Type), with `--dry-run` / `--auto` variants. Full contract: `references/verbs-fill.md`.
- **field** — two DISTINCT scripts (apply a preset vs bulk-fill one field by rule), including
  the default standardize-in-place migration. Full contract: `references/verbs-field.md`.
- **changelog** — generate the Keep-a-Changelog block from Done issues (dedup on `(#n)`
  citations; review before `-Write`). Full contract: `references/verbs-changelog.md`.
- **handoff** — save/resume curated cross-session context (`[abios-handoff]` comment + local
  file; refusal rules when no issue is linked). Full contract: `references/verbs-handoff.md`.
- **doctor** — audit local branches/worktrees against git reality (never `git branch --merged`
  here: this repo squash-merges). Full contract: `references/verbs-doctor.md`.
- **cerrar-ciclo** — classify the CURRENT branch and route it (commit/PR/gate/merge/teardown);
  performs exactly ONE action. Full contract: `references/verbs-cerrar-ciclo.md`.
- **telemetry** — the incremental field sweep over real session transcripts (watermarks, four
  mechanical signals, read-only). Full contract: `references/verbs-telemetry.md`.
- **triage** — fill Type/Area/Estimate from evidence and PROPOSE Priority (never write it
  silently). Full contract: `references/verbs-triage.md`.

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

Arguments: $ARGUMENTS
