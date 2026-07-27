---
name: board-expert
description: Auto-expert engine for /agentic-board:expert — take a tracked plan and execute it autonomously through a specialized expert persona (research, build, test with recorded evidence, self-drive the board), stopping only at the irreversible line. Owns the config (build the contract) and auto (launch the autonomous run) recipes. Routed by the expert command; never typed directly. Triggers — "/expert", "/board expert", "auto-experto", "corre el experto autónomo", "ejecuta el plan solo".
user-invocable: false
---

# board-expert — the auto-expert engine

The engine behind `/agentic-board:expert`. It turns a tracked plan (an epic + sub-issues carrying
the enriched items: Research, Role seed, Deliverables, Test plan) into an autonomous run that
adopts the required expert persona and executes it — freeing the user from real-time babysitting.

This skill is **internal** (`user-invocable: false`): it is routed by the `expert` command, never
typed with a slash.

## Two verbs

### config — define the contract
`scripts/Expert-Config.ps1 -PlanText "<plan text>" -PlanGoal "<goal>"`:
1. Detects the plan domain and hooks the installed skills/profiles for it (`Expert-RoleSynthesis`).
2. Synthesizes the role-as-objective (editable preview).
3. Writes `.agentic-board/expert.json` with the default contract (`ExpertContractIo`).

Show the role preview and let the user edit before running `auto`. See `references/contract.md`
for every contract field and its default.

### auto — run it
`scripts/Expert-Auto.ps1 -Issue <n> -ProjectNum <n>`:
1. Reads the contract; composes the autonomous brief.
2. Launches a dedicated Claude session in an isolated worktree (reuses the fleet/launch pattern).
3. Prints the monitor command: `/board work -Sessions -Watch`.

## Guiding principle: total self-use of agentic-board

The auto-expert does NOT improvise its own tooling — it dogfoods agentic-board at 100%:

| Need | Capability |
|---|---|
| Research / prior-art | `/knowledge add` + `/knowledge harvest` |
| Acquire / verify skills | `/skills bootstrap`, `/skills audit`, `/skills freshness` |
| Discover latent work | `/scan` |
| Record work / findings | `/board` issue, `/board plan`, `/board triage` |
| Report progress / evidence | `/board update`, `/board changelog`, `[abios-evidence]` comments |
| Survive budget / interruption | `/board handoff -Save` |
| Clean up | `/board doctor`, `/board cerrar-ciclo` |

## Autonomy boundary

Autonomous with a brake ONLY on the irreversible — merge to main, deploy, Fabric refresh, publish
externally, delete (`Expert-Autonomy.Test-IsIrreversible`, fail-safe: unknown ⇒ treated as
irreversible). Everything else the expert does on its own and records. It reaches "PR ready" and
stops there for the human to merge.

## Evidence (three places)

After each verify phase the run writes a structured `[abios-evidence]` block
(`Expert-Evidence.Format-EvidenceBlock`) to the PR body, a durable issue comment, and a versioned
`evidence/<issue>.md` file — so it is always provable that the tests ran and how they turned out.

## Building blocks (reused, not reinvented)

`ExpertContractIo.ps1` · `Expert-RoleSynthesis.ps1` · `Expert-Evidence.ps1` · `Expert-Autonomy.ps1`
· `Expert-Config.ps1` · `Expert-Auto.ps1` — plus the existing fleet/worktrees, `abios-feedback`,
review gate, and `Board-Handoff`.
