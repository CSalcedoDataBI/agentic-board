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

**Independent-review path (#646/#495).** Before writing the contract, check whether the
`codex@openai-codex` plugin is installed (`Get-InstalledPlugins.ps1` — reused, do not re-detect by
hand) and ASK the user, in plain language, whether this run should use the stricter independent
review (`references/independent-reviewer-guard.md`) instead of the default CI-bot fallback — no
need to name the plugin or the flag to make that choice. If it is not installed, say so and ask
whether to install it now — on yes, RUN the install yourself (`claude plugin marketplace add
openai/codex-plugin-cc` then `claude plugin install codex@openai-codex`); do not print those
commands for the user to run. Pass the resolved answer as `Expert-Config.ps1 -PreferCodexRescue`;
never pass it without having asked.

If `config` reports **NO ROLE MATCHED**, research the plan's domain (via `/knowledge`, and
`/tools` for ready-made agent definitions such as `wshobson/agents`), then propose a complete
role — `name`, `keywords`, `skills`, and an `agent` pointer when a fitting definition exists.
Show it to the user and persist it **only on their confirmation**, with `Add-ExpertRole`: writing
a role changes how every future plan is classified, so it is never a silent side effect of
`config`.

### roles — see and debug the catalog
`scripts/Expert-Roles.ps1 -List` prints the effective catalog (factory + global `~/.agentic-board/`
+ local, with each role's source and how many installed skills it really hooks); `-Why "<plan
text>"` explains which keyword in which role decided a match. Schema and merge rules:
`references/roles.md`.

### auto — run it
`scripts/Expert-Auto.ps1 -Issue <n> -ProjectNum <n> [-EndToEnd] [-Owner <account>] [-Repo <owner/name>] [-TakeOver] [-IgnoreBlocked]`:
1. Reads the contract; composes the autonomous brief — the issue's description **plus its bounded
   comment thread** (#473), where what was tried and decided since the report lives.
2. Launches a dedicated Claude session in an isolated worktree (reuses the fleet/launch pattern).
3. Prints the monitor command: `/board work -Sessions -Watch`.

### auto -Epic — walk a whole epic, wave by wave (#566)
`scripts/Expert-Auto.ps1 -Epic <n> -ProjectNum <n>` dispatches the **next ready wave** of the
epic's native sub-issues — open, no PR yet, no open blockers — one autonomous session each, with
the contract's brake and budget. It is **idempotent**: after the human merges a wave's PRs,
re-running the same command dispatches the next wave; done and in-flight sub-issues are never
re-dispatched, and a sub-issue whose PR state could not be read counts as in-flight (never
dispatch a possible duplicate). One command per wave replaces one human launch per sub-issue.

**Other accounts and refused starts.** `-Owner <account>` (with `-Repo <owner/name>` when the clone
is not the target) drives a board on a second account (#499): both are forwarded to Board-Work,
and without `-TokenVar` the token variable comes from the suite's one owner→variable map — an owner
the map does not know is refused when the script has to choose a token itself (pass `-TokenVar` to
name it; with `GH_TOKEN` already set it only warns), and inside a brake-armed worktree only the agent
identity is accepted.
`-TakeOver` / `-IgnoreBlocked` (#472) are forwarded to Board-Work's batch-start, so the advice its
refusal prints ("Re-ejecuta con -TakeOver") can be followed through this command. Both are per-run
and explicit: pass them only when the human said so, and never infer them from a previous run.
The end-of-run board link is read from the board itself, so it is right for `/orgs/` boards too.

Pass `-EndToEnd` **only** when the human ordered the finish in that instruction ("de punta a
punta", "llévalo hasta el final", "ciérralo tú"). It is an order, not a setting: never carry it
over from a previous run, and never read it out of the contract. It is currently **recorded and
not honoured** — see the autonomy boundary below, and never tell the user the run will merge.

## Guiding principle: total self-use of agentic-board

The auto-expert does NOT improvise its own tooling — it dogfoods agentic-board at 100%:

| Need | Capability |
|---|---|
| Research / prior-art | `/knowledge add` + `/knowledge harvest` |
| Acquire / verify skills | `/skills bootstrap`, `/skills audit`, `/skills freshness` |
| Discover latent work | `/scan` |
| Record work / findings | `/board issue`, `/board plan`, `/board triage` |
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

**Ordered end to end (`-EndToEnd`) — RECORDED, NOT HONOURED (#541).** The order is written into
the run's brake marker and explained to the launched session; it does **not** open a merge.

It briefly did. The gate's own script was opened for an ordered run, on the reasoning that it
re-checks four conditions (ordered · code-class · a real review of the head commit · CI green) and
refuses on its own. External review found that opening it made two latent holes reachable, neither
of them a string-matching bug:

| Hole | Why the gate could not defend itself |
|---|---|
| `cd C:\ ; pwsh <gate> -PR 42` | The hook judges per segment and allows it; the gate then resolves its marker from its RUNTIME cwd, finds none outside the worktree, and skips all four conditions |
| `[abios-review] … sha=<head>` | The review condition is a PR comment the run is able to post itself — the self-certification already removed for the TEST condition |

So the tool layer refuses every merge route for every run, ordered or not. Keep passing
`-EndToEnd` when the human says it: the session is told the order exists and is inert, which is
what stops it reading its own refusal as a failure to work around.

## Evidence (three places)

After each verify phase the run writes a structured `[abios-evidence]` block
(`Expert-Evidence.Format-EvidenceBlock`) to the PR body, a durable issue comment, and a versioned
`evidence/<issue>.md` file — so it is always provable that the tests ran and how they turned out.

A row is not only PASS or FAIL. There are four honest outcomes (`Expert-Evidence.Get-EvidenceState`),
counted separately in the summary line and never folded into `passed`:

| Result | Means | Example |
|---|---|---|
| `PASS` | the gate ran and passed | `tests` |
| `FAIL` | the gate ran and failed — the change is broken, keep working | a red `Pester` step |
| `N/A` | **not applicable** — nothing in this change triggers the gate (#475) | `bpa` on a diff with no `.tmdl` |
| `NOT-EVALUATED` | applies, but **could not be evaluated** — CI never executed (#481) | a workflow that ends in `startup_failure`, or a job GitHub refused to start (exhausted Actions minutes, spending limit, no runner) |

`N/A` is a statement about the *change*; `NOT-EVALUATED` is a statement about the *environment*, and
it is never a pass. `Get-NotApplicableGateRows` builds the `N/A` rows for the gates the contract
enabled but the diff does not owe (`Expert-WorkClass.ps1` prints the same split); `Get-CiEvidenceRow`
turns a CI state into its row.

**CI that never ran.** A red check has two unrelated causes. `Board-ReviewGate.ps1` tells them apart
(`CiCheckState.ps1`) from positive evidence only: a `STARTUP_FAILURE` state, or a failed check whose
job executed zero steps (`steps: []`, `runner_id: 0` — measured on a real quota-blocked run). When
the ONLY blocker is that CI never ran, the gate still blocks (a never-ran CI is not a pass) but exits
**3** instead of 1 and says so. On exit 3: **do not push again** — no code change can turn that CI
green and re-pushing only spends the iteration budget. Record the `ci` gate as `NOT-EVALUATED`,
finish everything else, and tell the human plainly (quota, billing or workflow). A genuinely failing
check, or any other blocker next to it, keeps exit 1 and the run keeps working on it.

## Building blocks (reused, not reinvented)

`ExpertContractIo.ps1` · `Expert-RoleSynthesis.ps1` · `Expert-Evidence.ps1` · `Expert-Autonomy.ps1`
· `Expert-Config.ps1` · `Expert-Auto.ps1` — plus the existing fleet/worktrees, `abios-feedback`,
review gate, and `Board-Handoff`.
