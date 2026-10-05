---
description: Run a tracked plan autonomously as an expert persona, stopping at the irreversible line — verbs config/auto/roles.
argument-hint: "[config|auto|roles] [args]"
---
You are running the agentic-board /expert command (typed as `/agentic-board:expert`).

**If $ARGUMENTS is empty or only whitespace, do NOT run anything yet.** Show this menu, translated
into the language the user is speaking (keep the verbs, arguments and numbering exactly as they
are), and wait for the user to pick (they can answer with just the number):

```
What do you want to do with the auto-expert?

1. config          → define the CONTRACT (expert role, autonomy, definition-of-done, evidence,
                     board self-use, budget). Runs nothing; leaves everything reviewable.
2. auto <issue>    → run the plan AUTONOMOUSLY: takes on the expert role, researches,
                     builds, tests while recording evidence, uses agentic-board itself for the
                     side work it finds, and BRAKES before anything irreversible (merge/
                     deploy/refresh/publish/delete) — leaves the PR ready for your OK.
2a. auto -Epic <n>  → WALK the whole epic, wave by wave: dispatches the READY sub-issues
                     (open, no PR, no open blockers), one autonomous session each.
                     Idempotent: you merge the wave's PRs and re-run the same command for
                     the next one. One command per WAVE instead of one launch per sub-issue.
2b. auto <issue> end to end
                   → RECORDS your order to finish it — but TODAY IT DOES NOT CLOSE ITSELF. The
                     mechanism that allowed it had two holes it could not defend
                     (issue #541), so it is shut: every merge route is refused for
                     every run. The session leaves the PR ready and you do the close, same as
                     without the order. You are told at launch; it does not fail silently.
3. roles [why "<text>"]
                   → show the effective role CATALOG (factory + your global `~/.agentic-board/` +
                     this project's local one, marking which overrides which and how many
                     skills it really hooks). With `why` it explains which role won for a plan
                     text and by which keyword.
4. verify <issue> <pr>
                   → CHECK that the run really left its evidence, instead of saying it
                     did: reads the three artifacts (versioned file, block in the PR,
                     comment on the issue) and answers COMPLETE or INCOMPLETE naming what is
                     missing. Fails closed: what cannot be read counts as absent.
```

First apply the `gh-account` skill to set `$env:GH_TOKEN` for the right account (your account
map's default). Then open the internal `board-expert` engine with the **Read** tool (it is a file, not a Skill-tool skill) at `${CLAUDE_PLUGIN_ROOT}/skills/board-expert/SKILL.md`, and follow it - it owns the full recipe.

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

## verify
Run `scripts/Expert-RunVerify.ps1 -Issue <n> -PR <n>`. It reads the three evidence artifacts a run
owes under its contract — `evidence/<issue>.md`, the `[abios-evidence]` block in the PR body, and
the `[abios-evidence]` comment on the issue — and prints COMPLETE or INCOMPLETE **naming every
artifact that is missing**, not just the first. Exit 1 when incomplete.

It fails closed: content it cannot read is missing content, never assumed present. That is the whole
point — a run that reports "evidence recorded" is making a claim about itself, and this is the one
claim it does not get to make. The `auto` brief instructs the run to quote this verdict in its final
report, so a run cannot report done while the check says otherwise.

The evidence file is resolved from the WORKING repository (git's toplevel, else the current
directory) — never relative to the script, which lives in the plugin cache once installed.

## roles
Run `scripts/Expert-Roles.ps1 -List`, or `scripts/Expert-Roles.ps1 -Why "<plan text>"`.

The catalog is `presets/roles.json` (factory) merged with `~/.agentic-board/roles.json` (this
user, every project, not versioned) merged with `.agentic-board/roles.json` (this project,
versioned in git). Precedence: local overrides global overrides factory, so a project can always
outrank both. A role hooking **0 skills** is printed in yellow: it will give the expert no
toolset. See `references/roles.md` for the schema and the merge rules.

## auto

**The end-to-end order (`-EndToEnd`) — RECORDED, NOT HONOURED.** When the user ORDERS the finish —
"de punta a punta", "llévalo hasta el final", "ciérralo tú", "end to end" — add `-EndToEnd`. It is
an ORDER, never a stored setting: it travels with that instruction and is good for that run only,
so never infer it from a previous run or from the contract. If the user did not say it, do not
pass it.

**It does not currently let the run merge.** The mechanism that honoured it opened the gate's own
script for an ordered run, and external review found that opening it made two holes reachable that
no command-string check can close (#541): changing directory before invoking the gate made the gate
skip all four of its conditions, and the "a real review exists" condition was satisfied by a PR
comment the run itself can post. So every merge route is refused for every run, ordered or not, and
deploy/publish/refresh/delete stay with the human as always.

Still pass it when the user says it: the launched session is told the order was given and cannot yet
be acted on, which is what stops it reading its own refusal as a failure to work around. And tell
the user plainly that the close is still theirs — never imply the run will finish it.

**Second account / refused start.** For a board on another account add `-Owner <account>` (and
`-Repo <owner/name>` when the clone is not the target); the token variable is then resolved from the
owner unless `-TokenVar` names one (an owner the suite does not know needs `-TokenVar`). When the launch refuses an issue another session claimed or a
blocker list flagged, `-TakeOver` / `-IgnoreBlocked` are forwarded to the launch — pass them only
when the user says so for THIS run, never from memory of a previous one.

Run `scripts/Expert-Auto.ps1 -Issue <n> -ProjectNum <n> [-EndToEnd]`. It reads the contract, composes the
autonomous brief (role objective + enriched plan + the issue's bounded comment thread + DoD + the
capability map + the irreversible line), and launches a dedicated Claude session in an isolated worktree (reusing the fleet/launch
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
