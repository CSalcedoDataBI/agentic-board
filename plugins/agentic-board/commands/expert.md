---
description: Auto-expert mode — take a tracked plan and execute it autonomously through a specialized expert persona (research, build, test with recorded evidence, self-drive the board), stopping only at the irreversible line. Three verbs: config (define the contract), auto (run it) and roles (browse the role catalog this project can extend, and explain why a plan matched).
---
You are running the agentic-board /expert command (typed as `/agentic-board:expert`).

**If $ARGUMENTS is empty or only whitespace, do NOT run anything yet.** Show this menu and wait
for the user to pick (they can answer with just the number):

```
¿Qué quieres hacer con el auto-experto?

1. config          → definir el CONTRATO (rol experto, autonomía, definition-of-done, evidencia,
                     auto-uso del board, presupuesto). No ejecuta nada; deja todo revisable.
2. auto <issue>    → ejecutar el plan de forma AUTÓNOMA: adopta el rol experto, investiga,
                     construye, prueba dejando evidencia, se auto-usa agentic-board para el
                     trabajo lateral que encuentra, y FRENA antes de lo irreversible (merge/
                     deploy/refresh/publish/delete) — deja el PR listo para tu OK.
2b. auto <issue> de punta a punta
                   → lo mismo, pero le DAS LA ORDEN de terminarlo. Sólo cierra su propio PR si
                     se lo gana: que el cambio sea CÓDIGO (un informe/página/tema lo sigues
                     aprobando tú), que haya REVISIÓN real de ese commit y que las PRUEBAS
                     hayan corrido en CI sobre él. Si falta algo, te dice cuál y el PR te espera.
                     Deploy/publish/refresh/delete siguen siendo tuyos, con orden o sin ella.
3. roles [why "<texto>"]
                   → ver el CATÁLOGO de roles efectivo (los de fábrica + los locales del
                     proyecto, marcando cuál sobreescribe a cuál y cuántas skills engancha de
                     verdad). Con `why` explica qué rol ganó para un texto de plan y por qué
                     keyword.
```

First apply the `gh-account` skill to set `$env:GH_TOKEN` for the right account (default
CSalcedoDataBI). Then apply the internal `board-expert` skill, which owns the full recipe.

## config
Run `scripts/Expert-Config.ps1 -PlanText "<plan/epic text>" -PlanGoal "<goal>"`. It detects the
plan's domain, hooks the installed skills/profiles for it, synthesizes the role-as-objective
(editable preview), and writes the contract to `.agentic-board/expert.json` with sane defaults:
autonomy brakes only on the irreversible, evidence goes to three places (PR + `[abios-evidence]`
issue comment + versioned file), board self-drive is on with a cap, and a budget bounds the run.
Show the role preview and let the user edit it before running `auto`.

If it reports **NO ROLE MATCHED**, research the plan's domain (via `/knowledge`, and `/tools` for
ready-made agent definitions such as `wshobson/agents`), propose a complete role — `name`,
`keywords`, `skills`, and an `agent` pointer when a fitting definition exists — and persist it with
`Add-ExpertRole` **only after the user confirms**: writing a role changes how every future plan is
classified, so it is never a silent side effect of `config`.

## roles
Run `scripts/Expert-Roles.ps1 -List`, or `scripts/Expert-Roles.ps1 -Why "<plan text>"`.

The catalog is `presets/roles.json` (factory) merged with `.agentic-board/roles.json` (this
project, versioned in git). Local roles are evaluated first, so a project can always outrank a
factory role. A role hooking **0 skills** is printed in yellow: it will give the expert no
toolset. See `references/roles.md` for the schema and the merge rules.

## auto

**The end-to-end order (`-EndToEnd`).** By default the run brakes at a reviewed PR and the merge
is yours. When the user ORDERS the finish — "de punta a punta", "llévalo hasta el final", "ciérralo
tú", "end to end" — add `-EndToEnd` to the command below. It is an ORDER, never a stored setting:
it travels with that instruction and is good for that run only, so never infer it from a previous
run or from the contract. If the user did not say it, do not pass it.

What the order does and does not do: it does NOT lift the brake. It opens exactly one path — the
gated `Board-Merge.ps1`, which re-checks four conditions at merge time (ordered · the change is
code-class · a real review of the head commit · CI passed on that commit) and refuses, naming
every unmet one, when they do not all hold. Raw `gh pr merge` and the REST merge endpoints stay
refused at the tool layer, and deploy/publish/refresh/delete stay with the human either way.

Run `scripts/Expert-Auto.ps1 -Issue <n> -ProjectNum <n> [-EndToEnd]`. It reads the contract, composes the
autonomous brief (role objective + enriched plan + DoD + the capability map + the irreversible
line), and launches a dedicated Claude session in an isolated worktree (reusing the fleet/launch
machinery). You are freed; monitor with `/board work -Sessions -Watch`. The launched session:

- **Becomes the expert** — researches prior-art via `/knowledge`, acquires tooling via `/skills`.
- **Builds test-first** and, after each verify phase, **records evidence** (three places).
- **Self-heals**: an in-scope problem it fixes in the loop; an out-of-scope finding it files as a
  sanitized `discovered` issue on the board and keeps going.
- **Loops** until the definition-of-done is green (leaves the PR ready and **brakes before merge**)
  or the budget is exhausted (`/board handoff -Save`).

**Guiding principle — total self-use of agentic-board:** the expert never improvises its own
tooling. Research → `/knowledge`, tooling → `/skills`, discover → `/scan`, findings → `/board`
issue, report → `/board update`, survive → `/board handoff`, cleanup → `/board doctor`.

Every response about a board operation must end with the board URL:
`https://github.com/users/<owner>/projects/<num>`.

Arguments: $ARGUMENTS
