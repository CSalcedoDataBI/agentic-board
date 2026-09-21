# Canonical skill layout & lint rules

## Canonical layouts (not misplaced)

| Repo kind | Canonical location | `project` inferred from |
|-----------|--------------------|-------------------------|
| Consumer repo / monorepo | `.claude/skills/<project>/<skill>/SKILL.md` | the `<project>` segment |
| Consumer, single project | `.claude/skills/<skill>/SKILL.md` | `(unpartitioned)` |
| Plugin source repo | `plugins/<plugin>/skills/<skill>/SKILL.md` | the `<plugin>` name |
| Personal (global) | `~/.claude/skills/<skill>/SKILL.md` | n/a |
| Plugin (installed) | `~/.claude/plugins/**/skills/<skill>/SKILL.md` | n/a (namespace `plugin:skill`) |

Anything else (a stray `SKILL.md` elsewhere in the repo) is **misplaced** and is what
Mode 2 relocates. In a monorepo the whole point is that project A's skills never mix with
project B's — hence one `<project>` folder per project under `.claude/skills`.

## Why this layout

- **No mixing:** each project owns its `.claude/skills/<project>/` subtree; nothing bleeds across.
- **Namespacing:** plugin skills carry a `plugin:skill` namespace and cannot collide with
  personal or project skills. Precedence is enterprise > personal > project, and any of those
  overrides a same-named bundled skill.
- **Progressive disclosure:** only `name` + `description` load at startup; the body loads on
  trigger; `references/*.md` load only when read. So the *count* of skills is cheap — the
  scarce resource is the **description budget** (~1% of context, 1536 chars/skill).

## Description lint (the routing surface)

The description is what Claude reads to pick a skill. Each rule below maps to a flag emitted
by `Get-SkillInventory.ps1`:

| Flag | Rule | Fix |
|------|------|-----|
| `thirdPerson` | Third person, not "I can…/Let me…" | "Processes X…", "Reviews Y…" |
| `hasTriggers` | Concrete trigger terms / "Use when…" | add the situations + keywords that should fire it |
| `hasWhenNotToUse` | A "when NOT to use → see X" clause | disambiguate from the neighboring skill |
| `lenOk` | ≤ 1536 chars, non-empty | trim; put the key use case FIRST (the tail truncates) |

Near-duplicate descriptions (keyword Jaccard ≥ 0.5, in the `overlaps` array) are the main
cause of mis-triggering. Resolve each by adding a disambiguation clause to both, or merging.

The same skill is often visible through several copies (repo tree, installed plugin cache,
marketplaces clone, worktrees). Copies with the same name and description are folded into one
before comparing, so a skill is never reported against itself; the number folded is
`summary.collapsedCopies`. Two copies of one name whose descriptions differ are reported as
`kind: divergent-copy` (one of them is stale — re-sync it), whatever their overlap.
`hasTriggers` accepts `Triggers: …`, `Triggers — …` and `Triggers – …` (space before the dash is fine).
