# Presets (`presets/`)

Factory data the plugin ships. Upgrades replace these files, so a preference belongs in an
override file, never in an edit here. The toolkit catalogs have their own page:
[`toolkits/README.md`](toolkits/README.md).

## CLI adapter registry (`adapters.json`)

One entry per AI CLI that `/board work -Fleet` can launch (claude, antigravity, jules, codex,
copilot). The fleet launcher, the fleet planner's routing and the review gate's reviewer roster
all read this one registry, so **adding a backend is a JSON entry, not a code change** (#772).

### Override tiers

The same three tiers as the expert role catalog (`roles.json`):

| File | Who edits it | Versioned | Applies to |
|------|--------------|-----------|------------|
| `presets/adapters.json` | the plugin (upgrades replace it) | plugin repo | every user, every project |
| `~/.agentic-board/adapters.json` | you | no - per machine/user | every one of your projects |
| `.agentic-board/adapters.json` | you | yes - team knowledge | this project only |

**Merge rule.** Tiers apply in that order. An override entry names an adapter; every field it
states **replaces that field wholesale** (a list or an object is replaced, not merged), fields it
omits are inherited, and the later tier wins. A name no earlier tier knows **adds** an adapter, and
then `name`, `command`, `kind`, `probeArgs`, `probeRules` and `launch` are required (the rest
default to false / empty). An override file holds `{ "version": 1, "adapters": [ ... ] }` only:
`routes` and `commonProbeRules` are the factory's vocabulary and are ignored, with a warning, if an
override sets them.

**Invalid files.** As with `roles.json`, an override file that does not parse, or declares another
`version`, is ignored with a warning. An override **entry** is validated on the merged result; if it
fails, only that entry is rejected (with a warning naming the reason) and the previous tier's
definition stays. A broken `presets/adapters.json` is a broken install and stops the run.

Example - a user tier that keeps one more credential for codex and adds a backend for docs work:

```json
{
  "version": 1,
  "adapters": [
    { "name": "codex", "keepEnv": ["OPENAI_API_KEY", "CODEX_HOME"] },
    {
      "name": "acme",
      "command": "acme",
      "kind": "repl",
      "installArgs": ["npm", "i", "-g", "@acme/cli@2.3.4"],
      "probeArgs": ["acme", "whoami"],
      "probeRules": [
        { "code": "AUTH", "pattern": "(?i)please log in", "reason": "not logged in" },
        { "include": "common" },
        { "code": "OK", "pattern": "(?im)^signed in as", "reason": "signed in" }
      ],
      "bypassArgs": "--yes-to-all",
      "launch": { "args": ["run", "--prompt", "{briefingContent}"] },
      "routing": { "docs": 50 },
      "reviewer": true
    }
  ]
}
```

### Adapter fields

| Field | Meaning |
|-------|---------|
| `name` | Id used everywhere (lower-case letters, digits, `-`). |
| `note` | Free text, ignored by the loader - JSON has no comments, so the *why* lives here. |
| `command` | Executable that must be on PATH - a bare name, no path. |
| `kind` | `repl` (live tab in the worktree) or `async` (dispatches a cloud task). |
| `isDefault` | `true` for claude only: the fallback for an unavailable CLI is hard-wired to claude. |
| `installArgs` | Exactly `["npm", "i", "-g", "<package>@x.y.z"]` (an exact version, #765), or `null`. |
| `installUrl` | An `https://` page for a CLI with no pinnable package (shown, never run). |
| `probeArgs` | The cheapest command that proves auth, starting with `command`; never the bypass flag (#761). `null` only for claude, the host CLI. |
| `probeRules` | Ordered `{ code, pattern, reason }` rules; first match wins. `code` must be one of `OK`, `AUTH`, `RATE_LIMIT`, `QUOTA`, `CONTEXT_WINDOW`, `ERROR` (#770) and exactly one rule is `OK` (positive evidence; it only counts on exit 0). `{ "include": "common" }` splices in `commonProbeRules` at that spot. |
| `bypassArgs` | The CLI's permission-bypass flags, added only with `-AllowPermissionBypass` (#761). |
| `requiresBypass` | `true` if the CLI cannot work unattended without the bypass (the picker hides it otherwise). |
| `keepEnv` | Environment variables the secret scrub keeps for this CLI (#769). |
| `launch` | `{ "args": [...], "stdinNull": false }` - see below. Not needed for claude. |
| `routing` | `{ "<route>": rank }` - the fleet routes this CLI suits; a lower rank is preferred. |
| `reviewer` | `true` to list it in the review gate's reviewer roster (probed with `probeArgs`). |

### Launch templates

`launch.args` are written after `command`, in order. `{briefingContent}` as a whole argument
becomes the briefing file's text, read when the session starts; `{briefingFile}` inside an argument
becomes the briefing path. `stdinNull: true` pipes `$null` in, for a CLI that waits on stdin even
with a prompt argument. The bypass flags are appended only on opt-in.

Templates are data, never code: an argument is written as a plain token only when it is one (letters,
digits and `-_.:=/`), and otherwise as a single-quoted literal with every quote doubled, so a path
like `C:\Users\O'Brien\...` - or a hostile override - cannot break out of the generated launch
script. `command` and `bypassArgs` are restricted to bare tokens on load for the same reason.
claude's launch stays in code (`Build-ClaudeLaunch`): it sets up the auth variable over several
statements before the CLI starts, which an argument list cannot express.

### Routes

`routes` lists the fleet planner's routes in order; an issue takes the **first** one it matches by
label, type or size (a route with no criteria matches everything). Within the route, the available
CLI with the lowest `routing` rank wins, then claude, then the first available CLI. With the
shipped registry:

| Route | Matches | Preference |
|-------|---------|------------|
| `heavy` | label security / architecture, type Spike, size L / XL | claude |
| `refactor` | label or type Refactor | codex, claude |
| `docs` | label docs / documentation, type Docs | antigravity, copilot, claude |
| `chore` | type Chore, size S / XS | copilot, antigravity, claude |
| `default` | anything else | claude |

`commonProbeRules` are the API-failure phrases several CLIs share. They are phrases, not bare
words: a healthy banner can say "Quota remaining: 500" or carry "401" inside an id (#537), and QUOTA
is checked before RATE_LIMIT because "429: quota exceeded" is the long wait.
