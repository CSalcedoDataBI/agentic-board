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

If `config` reports **NO ROLE MATCHED**, research the plan's domain (via `/knowledge`, and
`/tools` for ready-made agent definitions such as `wshobson/agents`), then propose a complete
role — `name`, `keywords`, `skills`, and an `agent` pointer when a fitting definition exists.
Show it to the user and persist it **only on their confirmation**, with `Add-ExpertRole`: writing
a role changes how every future plan is classified, so it is never a silent side effect of
`config`.

### roles — see and debug the catalog
`scripts/Expert-Roles.ps1 -List` prints the effective catalog (factory + local, with each role's
source and how many installed skills it really hooks); `-Why "<plan text>"` explains which keyword
in which role decided a match. Schema and merge rules: `references/roles.md`.

### auto — run it
`scripts/Expert-Auto.ps1 -Issue <n> -ProjectNum <n> [-EndToEnd]`:
1. Reads the contract; composes the autonomous brief.
2. Launches a dedicated Claude session in an isolated worktree (reuses the fleet/launch pattern).
3. Prints the monitor command: `/board work -Sessions -Watch`.

Pass `-EndToEnd` **only** when the human ordered the finish in that instruction ("de punta a
punta", "llévalo hasta el final", "ciérralo tú"). It is an order, not a setting: never carry it
over from a previous run, and never read it out of the contract. See the autonomy boundary below
for what it actually opens.

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

The brake is mechanical, not prose: `Start-WorktreeSession` writes `.agentic-board/brake-armed.json`
into the launched worktree and a PreToolUse hook refuses the call before it runs.

**Ordered end to end (`-EndToEnd`).** The order does not lift the brake — it opens exactly one
path. `Board-Merge.ps1` (the only merge route that checks anything) becomes reachable, and it
re-establishes four conditions at merge time, refusing while naming every unmet one:

| Condition | Why it is separate |
|---|---|
| the owner ordered it | permission travels with the instruction, not with a file |
| the change is code-class | what he judges by LOOKING at it stays his, ordered or not |
| a real review of THIS commit | a green check is not a review |
| CI passed on THIS commit | the run may not certify its own testing |

Raw `gh pr merge`, the REST merge endpoints and `gh` reached through a variable stay refused at
the tool layer even when ordered, so the order NARROWS the route to a merge instead of widening
it. Deploy/publish/refresh/delete are never covered by it.

## Evidence (three places)

After each verify phase the run writes a structured `[abios-evidence]` block
(`Expert-Evidence.Format-EvidenceBlock`) to the PR body, a durable issue comment, and a versioned
`evidence/<issue>.md` file — so it is always provable that the tests ran and how they turned out.

## Building blocks (reused, not reinvented)

`ExpertContractIo.ps1` · `Expert-RoleSynthesis.ps1` · `Expert-Evidence.ps1` · `Expert-Autonomy.ps1`
· `Expert-Config.ps1` · `Expert-Auto.ps1` — plus the existing fleet/worktrees, `abios-feedback`,
review gate, and `Board-Handoff`.
