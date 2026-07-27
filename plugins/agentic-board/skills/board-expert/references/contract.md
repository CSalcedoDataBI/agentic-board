# The /board expert contract (`.agentic-board/expert.json`)

`config` writes it, `auto` reads it. A partial on-disk contract is deep-merged over the defaults
on read (`ExpertContractIo.Read-ExpertContract`), so `auto` never hits a missing setting.

| Key | Default | Meaning |
|---|---|---|
| `role` | *(synthesized)* | The role-as-objective the auto-expert adopts (`Expert-RoleSynthesis`). |
| `autonomy.irreversible` | `merge, deploy, refresh, publish, delete` | The ONLY actions that stop the run for the human. Anything not here and not explicitly safe is treated as irreversible (fail-safe). |
| `dod` | `ci, build, lint, tests, bpa, tmdlBreaking` all `true` | The definition of done the loop drives toward ("everything passes"). |
| `evidence.pr` / `.issueComment` / `.file` | all `true` | The three destinations the evidence block is written to. |
| `boardSelfDrive.createIssues` | `true` | May file issues for out-of-scope findings on its own. |
| `boardSelfDrive.label` | `discovered` | Label applied to self-filed issues. |
| `boardSelfDrive.cap` | `10` | Max issues one run may create (beyond it, group findings). |
| `budget.maxIterations` | `8` | Loop iterations before giving up → handoff. |
| `budget.maxMinutes` | `120` | Wall-clock budget before giving up → handoff. |
| `capabilities.knowledge` | `true` | May use `/knowledge` for research. |
| `capabilities.skillsBootstrap` | `true` | May use `/skills bootstrap` to acquire tooling. |
| `capabilities.toolsInstall` | `false` | May install external tools (off by default — opt in). |
| `capabilities.scan` | `true` | May use `/scan` to discover latent work. |

## Editing

The contract is plain JSON — edit any value by hand, or re-run `config` to regenerate the role.
By default it is gitignored (a process file); version it deliberately if the team wants a shared,
reviewed contract.
