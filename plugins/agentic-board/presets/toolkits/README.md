# Toolkit catalogs (`presets/toolkits/`)

Curated catalogs of **external** skills/tools that the `skills-ops` module can *reference,
install, and monitor* — it never re-implements them. Each file is one **profile-family** of
tools; `skills-bootstrap` reads the catalog by profile (see #332), installs only the gaps
(clean clone, license preserved), and the freshness monitor (see #333) tracks whether the
installed copy still matches upstream.

| Catalog | Profiles | What it provisions |
|---------|----------|--------------------|
| `quality.json` | `quality` | Skill-authoring/review toolkit (skill-creator, writing-skills, …) |
| `bi.json` | `semantic-model-review`, `fabric-app`, `data-agent` | Microsoft Fabric / Power BI ecosystem tools |
| `mcp.json` | `documentation` | MCP servers installable via `claude mcp add` (e.g. DeepWiki) |

## Entry schema

Every catalog is a JSON array of entries with these keys (all required):

| Key | Type | Meaning |
|-----|------|---------|
| `name` | string | Canonical skill/tool name — matched (case-insensitive) against the live inventory so nothing is installed twice. |
| `owner` | string | Who publishes it. Surfaced at list/install time — the attribution ("who owns each tool"). |
| `repo` | string | GitHub `owner/name`. |
| `kind` | `"skill-clone"` \| `"plugin"` \| `"mcp"` | How it installs (see below). |
| `detect` | string \| null | *(plugin/mcp)* the id to match against `claude plugin list` / `claude mcp list`. Falls back to `name` when absent. Omit / `null` for `skill-clone`. |
| `path` | string \| null | Subpath to the skill folder for `skill-clone`; `null` for `plugin`. |
| `license` | string | SPDX id or short label — copied next to the installed skill (mandatory for CC BY-SA). |
| `homepage` | string | URL to the tool's home. |
| `profiles` | string[] | One or more task bundles this tool belongs to (min 1). |
| `install` | string \| null | Exact install command for `plugin` kind; `null` for `skill-clone` (installed via `Install-SkillFromRepo.ps1`). |
| `purpose` | string | One line — what it does. |

### `kind`

- **`skill-clone`** — a skill folder inside a repo. Installed by `Install-SkillFromRepo.ps1`
  (shallow clone → copy the `path` folder into `~/.claude/skills/<name>` → copy the source
  `LICENSE`). `path` is required; `install` is `null`. This is how the user's own public repos
  and other developers' skill folders are added.
- **`plugin`** — a whole Claude Code plugin/marketplace (has a `.claude-plugin/marketplace.json`).
  Not folder-cloned: the installer **emits the exact `install` command** for the user to run
  (installing third-party plugins is deliberately not automated). `path` is `null`.
- **`mcp`** — a Claude Code MCP server, installed with `claude mcp add`. Like `plugin`, the
  installer **emits the exact `install` command** for the user to run. Detection uses
  `claude mcp list` (via `Get-InstalledMcpServers.ps1`). `path` is `null`.

## Adding an entry

Edit the JSON directly (curated preset — changes go through a PR). Never invent a repo: verify it
exists and read its license first (`gh repo view <owner/name>`, `gh api repos/<owner/name>/contents/LICENSE`).
User-owned BI repos are added as `skill-clone` entries in `bi.json` once named and verified.

## How the reader uses this

`Get-SkillGaps.ps1 -Profile <name>` reads `presets/toolkits/<name>.json` and reports installed
vs gaps. Detection is by kind: `skill-clone` entries match `name` against the installed skill
inventory; `plugin` entries match `detect` (marketplace/plugin id from `claude plugin list`);
`mcp` entries match `detect` (server name from `claude mcp list`).
`skills-bootstrap` then installs only the gaps — cloning `skill-clone` folders and emitting the
`install` command for `plugin` and `mcp` entries.
