---
name: tools-catalog
description: Use to browse, research and install the project's referenced external tools from one unified catalog that merges the knowledge registry (references) with the installable toolkit presets. Install one tool or all missing installables at once, kind-aware (skill-clone preserves LICENSE; a plugin surfaces its own install command, never cherry-picked). The discoverability surface at the intersection of knowledge-ops and skills-ops. Triggers — "/tools", "navega las herramientas referenciadas", "instala esta herramienta", "instálalas todas", "qué herramientas hay para instalar".
user-invocable: false
---

# tools-catalog — unified referenced-tools catalog (browse · research · install)

The single browsable surface for the external tools this project *references* and can *install*.
It merges two sources that until now lived apart:

- **References** — `knowledge/registry.json` (the knowledge-ops registry): every catalogued
  URL / repo / doc, by domain. This is *what exists and why* — not necessarily installable.
- **Installers** — `presets/toolkits/*.json` (the skills-ops toolkit presets, e.g. `bi.json`,
  `quality.json`): the curated tools that carry an install method. This is *what can be installed*.

A tool can appear in one source or both. The catalog is their union, de-duplicated, each item
carrying: `name, domain, kind, url, installable, install-method, installed`.

> **Scope (M3 ∩ M5).** This surface REFERENCES / INSTALLS / MONITORS external tools — it never
> rebuilds them. It reuses the existing engines (`Get-SkillGaps.ps1` for installed-detection,
> `Install-SkillFromRepo.ps1` for skill-clone); it does not reimplement install or gap logic.

## Sub-actions

### browse  (read-only, no token)
Run `scripts/Show-ToolsCatalog.ps1` — it renders the unified catalog grouped by domain, each row
showing `[installed|available|reference]`, the id, the kind, and the URL. It reads
`scripts/Get-ToolsCatalog.ps1` under the hood (registry + presets merged, installed-state via the
`Get-SkillGaps` rules); pass `-Json` to the resolver directly when you need the raw item model.

### research <id>  (read-only)
Run `scripts/Show-ToolsCatalog.ps1 -Id <id>` — it surfaces ONE tool's name, source, URL, install
method and note so the user reads the reference before deciding. `<id>` matches the row id or the
tool name (case-insensitive). Never installs anything.

When the tool has a `repo` field pointing to a public GitHub repository, **use the DeepWiki
MCP as the first probe** — before any clone or web fetch:
1. Call `ask_question` with the repo URL and the question `"What does this repository do?"` to
   get a plain-language description directly from the generated wiki.
2. If DeepWiki MCP is not configured or the repo is private, skip this probe and show only the
   catalog entry.
This gives the user an authoritative, wiki-quality description in one call, with no cloning.

### install <id>  (confirm each; never duplicate)
Run `scripts/Install-ToolFromCatalog.ps1 -Id <id>` — it resolves the item and installs by KIND:
- `skill-clone` → delegates to `Install-SkillFromRepo.ps1` (clean `--depth 1` clone, copy only the
  skill folder, **preserve LICENSE**). Skipped with a note when it already shows as installed.
- `plugin` (e.g. `microsoft/skills-for-fabric`) → all-or-nothing: it SURFACES the install command for
  the user to run, never cherry-picking a single skill out of it.
- `mcp` (e.g. `deepwiki-mcp`) → it SURFACES the `claude mcp add` command for the user to run.
  Detection uses `claude mcp list` so already-installed servers are skipped.
- a bare `reference` (not installable) → reports the URL to open instead.
Confirm before running; `-DryRun` previews. `<id>` matches the row id or the tool name.

### install --all  (one pass, one confirmation)
Run `scripts/Install-ToolFromCatalog.ps1 -All` — it lists every MISSING installable, skill-clones and
plugins SEPARATELY, and is a safe preview by default (installs nothing). Show that plan to the user,
get ONE confirmation, then re-run with `-All -Yes` to clone the skill-clones; plugin entries are
always surfaced (their install command printed) for the user to run, never installed blindly.

## Identity
`browse` and `research` need no token. An install that clones or files follows the `gh-account`
discipline (default CSalcedoDataBI) like the rest of the suite.

## Not this
- Managing the references themselves (add / harvest / wiki) → the `knowledge-registry` skill.
- Installing a whole profile toolkit without the catalog UI → the `skills-bootstrap` skill.
- Auditing installed skills' health → `skills-organize` / `skills-audit`.
