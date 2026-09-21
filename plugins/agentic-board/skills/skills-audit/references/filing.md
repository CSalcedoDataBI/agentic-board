# Sanitized filing recipe

The same discipline as `abios-feedback`, applied to skill-audit findings. Two hard rules:
**file to the OWNER repo, never the current project** — and **strip every trace of private
context** before anything leaves the machine.

## 1. Abstract locally (you do this, in your head / in the draft)

Keep: the public file path (`skills/…`, `scripts/…`), the wrong behavior (the flag/description/
trigger that failed), the generic repro, the failure type.

Strip: private repo names, client/customer names, data values, row counts, Fabric/PBI GUIDs,
OneLake paths, secrets/tokens, internal URLs, screenshots. If the failure only reproduces with
private data, rewrite it as a synthetic repro ("on any repo, description X fails to trigger on
prompt Y").

## 2. Route by the finding's `filing` field

| `filing` | Where | How |
|----------|-------|-----|
| `file` + ownerRepo = `CSalcedoDataBI/agentic-board` | the tool's own board | tool PAT + `skill-eval` label (below) |
| `file` + ownerRepo = current project | the project's own board | `project-scan` / `projects-admin` issue flow on that repo |
| `local` | nowhere — in-session report | hand it to the user to file upstream themselves |

`local` includes every plugin skill whose owner could not be verified (no manifest, unreadable
manifest, or a plugin that only *names* itself `agentic-board` without declaring this tool's repo):
an empty or non-`owner/repo` `ownerRepo` means "do not file". A finding's `paths` and `copies` are
local evidence; never paste them into an issue.

## 3. Create the sanitized issue (tool-owned skills)

Load the tool account via `gh-account` and file to a CONSTANT target — never resolved from the
current repo:

```powershell
$env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL','User')
gh label create skill-eval --color 5319E7 --description "Skill failure found by skills-audit" --force `
  --repo CSalcedoDataBI/agentic-board
$url = gh issue create --repo CSalcedoDataBI/agentic-board --label skill-eval `
  --title "<skill>: <failure type> — <one line>" `
  --body  "<sanitized: public path, wrong behavior, generic repro, failure type>"
gh project item-add 13 --owner CSalcedoDataBI --url $url
```

For a project-owned skill, do the same against the project's repo/board (resolve it with
`Resolve-Board.ps1`) — the finding's `ownerRepo` is that repo.

## 4. The gate and the backstop

- **Human gate:** show the user the exact title + body and get an explicit yes BEFORE `gh issue
  create`. Findings never auto-file.
- **Backstop:** the repo's `guard-no-private.ps1` (pre-commit/pre-push) scans added lines for
  secrets + the local denylist. It is the safety net, not the sanitization step — do the
  abstraction yourself; the guard only catches what you missed.
