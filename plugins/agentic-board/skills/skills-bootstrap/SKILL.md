---
name: skills-bootstrap
description: "Engine behind /skills bootstrap: install the missing tools of a profile (quality, or bi = Fabric/Power BI) without duplicating installed ones, keeping each LICENSE. Triggers — \"bootstrap skills\", \"instala el toolkit de BI\", \"qué me falta del perfil bi\"."
user-invocable: false
disable-model-invocation: true
---

# skills-bootstrap — curated toolkits by profile, no duplicates

Part of the **skills-ops** module. Detects gaps against what is actually installed, then
installs only what is missing — never re-installing something you already have (any scope).

## Profiles

The catalog lives in `presets/toolkits/<profile>.json`. Pick a profile:

| Profile | What it provisions |
|---------|--------------------|
| `quality` (default) | Skill-authoring/review toolkit (skill-creator, writing-skills, skill-improver, second-opinion) |
| `bi` | Microsoft Fabric / Power BI ecosystem — e.g. `microsoft/skills-for-fabric` (semantic-model-review, fabric-app, data-agent) |

See `presets/toolkits/README.md` for the entry schema and how to add tools (including the user's
own public repos, or another developer's — always with attribution).

## Step 1 — Detect the gap (deterministic)

```powershell
$g = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-SkillGaps.ps1" -Profile bi   # omit -Profile for 'quality'
$g.summary
"Installed:"; $g.installed | Select-Object name,owner,license | Format-Table
"Gaps:";      $g.gaps      | Select-Object name,owner,repo,kind,license,purpose | Format-Table
```

Detection is deterministic and per-kind, so nothing is duplicated:
- **`skill-clone`** counts as installed if its `name` appears anywhere in the inventory
  (plugin / personal / project) — `anthropic-skills:skill-creator` already covers `skill-creator`.
- **`plugin`** counts as installed if its `detect` id (the marketplace/plugin from
  `claude plugin list`) is present — so `microsoft/skills-for-fabric` is detected via its
  `fabric-collection` marketplace even though no skill is literally named `skills-for-fabric`.

## Step 2 — Install only the gaps (by kind, confirm each with the user)

**`skill-clone`** — clean clone, license preserved:

```powershell
& "${CLAUDE_PLUGIN_ROOT}/scripts/Install-SkillFromRepo.ps1" `
    -Repo <owner/name> -Path <subpath> -Name <skill-name>
```

It shallow-clones to a temp dir, copies only that skill folder into `~/.claude/skills/<name>`,
copies the source `LICENSE` next to it (mandatory for CC BY-SA sources), and cleans up. It
**skips** an already-present skill unless `-Force`.

**`plugin`** — do NOT auto-install a third-party plugin. Surface the entry's own `install`
command and let the user run it, e.g.:

```
# from the gap entry's `install` field:
claude plugin marketplace add microsoft/skills-for-fabric
# then install the plugin(s) you want from that marketplace with `claude plugin install`.
```

## Step 3 — Verify

Re-run `Get-SkillGaps.ps1 -Profile <p>` — `summary.gaps` should drop. Restart the session so
new skills/plugins load. Report what was installed, from where, and under which license/owner.

## Rules
- Never install something that already exists in any scope (Step 1 enforces this).
- Always preserve the upstream LICENSE/attribution — especially CC BY-SA.
- Never invent a repo: entries are curated in `presets/toolkits/*.json` and verified before use.
- General-purpose skills go to the global `~/.claude/skills/`; project-specific ones go to the
  repo's `.claude/skills/` instead.
