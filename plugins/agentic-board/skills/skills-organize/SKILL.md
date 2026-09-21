---
name: skills-organize
description: Use to inventory and organize Agent Skills in a repo or monorepo — a read-only catalog + health report (description lint, near-duplicate detection, misplaced/orphaned skills) and a propose-then-confirm reorganize that moves scattered SKILL.md files into the canonical .claude/skills/<project>/<skill>/ layout with git mv (dry-run first, fully reversible) and writes a skills-index.json. Use when skills are scattered across a messy monorepo, when you want a catalog of what is installed, or before auditing skill quality. Triggers — "organiza mis skills", "cataloga las skills", "skills regadas/desordenadas", "skills health", "reorganiza el monorepo", "no mezclar skills", /skills organize.
user-invocable: false
---

# skills-organize — catalog, health, and repo layout for Agent Skills

Part of the **skills-ops** module. Two modes over one engine
(`scripts/Get-SkillInventory.ps1`). Never touches the plugin cache or `~/.claude/skills`
— only the project skills inside the target repo. See `references/layout.md` for the
canonical layout and the lint rules.

## Mode 1 — Report (read-only, the default)

Answers "what skills do I have and are they healthy?". Run the engine and summarize.

```powershell
$inv = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-SkillInventory.ps1" -Root . -Scope all
```

Present, grouped by scope (plugin / personal / project):

- **Catalog** — name, namespace, project, one-line description.
- **Health flags** (the description is the routing surface, so lint it):
  - `lint.thirdPerson` false → rewrite from first person ("I can…") to third person.
  - `lint.hasTriggers` false → add concrete trigger terms / "Use when…".
  - `lint.hasWhenNotToUse` false → add a "when NOT to use → see X" clause (the #1 lever against mis-triggering between neighbors).
  - `budget.overCap` true → description over the 1536-char cap; it gets truncated (a silently weakened skill).
- **near-duplicates** — the `overlaps` array (description keyword Jaccard ≥ 0.5). Each pair needs a disambiguation edit or a merge. Copies of one skill (same name and description) are folded first and counted in `summary.collapsedCopies`; copies of one name with different descriptions come back as `kind: divergent-copy` (a stale copy).
- **misplaced / orphaned** — `misplaced=true` means a SKILL.md outside `.claude/skills` (or `plugins/*/skills`); candidates for Mode 2.

> The `budget` block is a **proxy** for Claude Code's `doctor` health view (which is a
> terminal dialog this skill cannot invoke). It estimates per-skill cap pressure, not the
> exact shortened/dropped set. Say so when reporting.

Scope to just the current repo with `-Scope project`; add `-Json` for machine output.

## Mode 2 — Reorganize (propose → confirm → move)

Answers "put my scattered skills in order without mixing projects". Only relocates
**misplaced** project skills into `.claude/skills/<project>/<skill>/`.

1. **Dry-run first (always):** show the from→to plan, change nothing.
   ```powershell
   & "${CLAUDE_PLUGIN_ROOT}/scripts/Move-SkillsLayout.ps1" -Root .
   ```
2. **Confirm with the user.** Print the plan and ask (yes/no). If a skill's inferred
   project (its top-level folder) is wrong, pass `-Map @{ 'skill-name' = 'project' }`.
3. **Apply** (requires a clean git tree — commit/stash first, or `-Force`):
   ```powershell
   & "${CLAUDE_PLUGIN_ROOT}/scripts/Move-SkillsLayout.ps1" -Root . -Apply
   ```
   Moves each skill's directory with `git mv` (history preserved), then writes
   `.claude/skills/skills-index.json`. The script prints the exact **revert** command.
4. The moves are staged, not committed — review `git status`, then commit through the
   normal flow (a PR when the work is board-tracked).

**Safety rules (enforced):**
- Default is dry-run; `-Apply` is required to move anything.
- Clean git tree required for `-Apply` so the printed revert is exact.
- Never moves plugin-source skills (`plugins/*/skills/*`) or anything outside `-Root`.

## Verification checklist
- Reported the budget block as a proxy, not exact `doctor` output?
- Showed the dry-run plan and got confirmation before `-Apply`?
- After apply: skills resolve under `.claude/skills/<project>/<skill>/` and
  `skills-index.json` lists them? (`git status` shows only renames + the index.)
