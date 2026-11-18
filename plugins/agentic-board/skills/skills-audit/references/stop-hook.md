# Passive Stop hook (opt-in, suggest-only)

`<tools>/scripts/SkillAudit-StopHook.ps1` is a **Phase-2, opt-in** nudge. It is NOT enabled by
default — a hook that runs on every stop is noisy, so you turn it on deliberately.

## What it does

On each Claude stop it runs a fast static audit of the current repo's **project** skills.
If there are findings it appends ONE line to `.agentic-board/skill-suggestions.jsonl`
(gitignored, local) and prints a one-line nudge:

```
skills-ops: 3 skill finding(s) — run /skills audit.
```

It never opens an issue, never edits a skill, never blocks, and never throws. It is the
**passive capture** — the human still runs `/skills audit` to review and (with an explicit
yes) file anything. This is the documented guardrail against self-improvement drift: suggest,
don't act.

## Enable it (settings.json Stop hook)

Add to `.claude/settings.json` (project) or `~/.claude/settings.json` (global):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"<tools>/scripts/SkillAudit-StopHook.ps1\" -Quiet"
          }
        ]
      }
    ]
  }
}
```

Drop `-Quiet` to also print the nudge line. Review the breadcrumbs anytime:

```powershell
Get-Content .agentic-board/skill-suggestions.jsonl | ForEach-Object { $_ | ConvertFrom-Json }
```

## Disable it

Remove the Stop hook entry. The suggestions file is safe to delete; it is local and
gitignored.
