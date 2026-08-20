# The /board expert contract (`.agentic-board/expert.json`)

`config` writes it, `auto` reads it. A partial on-disk contract is deep-merged over the defaults
on read (`ExpertContractIo.Read-ExpertContract`), so `auto` never hits a missing setting.

| Key | Default | Meaning |
|---|---|---|
| `role` | *(rendered)* | The role-as-objective the auto-expert adopts. Rendered from the role catalog (`presets/roles.json` + `.agentic-board/roles.json`) — to change it, edit the catalog, not this value. See `roles.md`. |
| `roleMatched` | *(computed)* | `false` when no role matched the plan, so `config` can offer to synthesize one instead of silently running as `generic`. |
| `roleAgent` | *(computed)* | The agent definition the matched role names, if any — passed to the launched run as its agent type. |
| `autonomy.irreversible` | `merge, deploy, refresh, publish, delete` | The ONLY actions that stop the run for the human. Anything not here and not explicitly safe is treated as irreversible (fail-safe). |
| `dod` | `ci, build, lint, tests, bpa, tmdlBreaking` all `true` | The definition of done the loop drives toward ("everything passes"). |
| `evidence.pr` / `.issueComment` / `.file` | all `true` | The three evidence surfaces. Since #570 only `.file` (`evidence/<issue>.md`) carries the FULL block — the single source of truth; `.pr` and `.issueComment` carry the link stub (marker + summary + link), so nothing is written three times. |
| `review.preferCodexRescue` | `false` | (#646) Opt-in: route independent review through the `codex:codex-rescue` agent (a disk-verified marker, #637/#644) instead of the CI-bot fallback. `config -PreferCodexRescue` sets it — and only ever to `true` when the `codex@openai-codex` plugin is actually detected installed; a request with the plugin missing is refused and reported, never written as a silent `true` the launched run could not honour. |
| `boardSelfDrive.createIssues` | `true` | May file issues for out-of-scope findings on its own. |
| `boardSelfDrive.label` | `discovered` | Label applied to self-filed issues. |
| `boardSelfDrive.cap` | `10` | Max issues one run may create (beyond it, group findings). |
| `budget.maxIterations` | `8` | Loop iterations before giving up → handoff. |
| `budget.maxMinutes` | `120` | Wall-clock budget before giving up → handoff. |
| `capabilities.knowledge` | `true` | May use `/knowledge` for research. |
| `capabilities.skillsBootstrap` | `true` | May use `/skills bootstrap` to acquire tooling. |
| `capabilities.toolsInstall` | `false` | May install external tools (off by default — opt in). |
| `capabilities.scan` | `true` | May use `/scan` to discover latent work. |
| `workClass.visualPatterns` | *(see `Expert-WorkClass.New-WorkClassPolicy`)* | Globs whose changes are judged by LOOKING (reports, pages, images) — any match routes the change to the owner. |
| `workClass.codeExceptions` | `[]` | Globs SUBTRACTED from `visualPatterns` (#567): web-tech paths that are plumbing, judged by reading (e.g. `src/components/**/*.css`). Declared per project, never guessed — in a web app, without exceptions every change is "visual" and the classification stops carrying information. |
| `workClass.humanApproves` | `visual` | The classes the owner always approves personally. Approval is per SECTION (top-level directory batch), not per file. |

## Editing

The contract is plain JSON — edit any value by hand, or re-run `config` to regenerate the role.
By default it is gitignored (a process file); version it deliberately if the team wants a shared,
reviewed contract.
