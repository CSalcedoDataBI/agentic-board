# /board plugins — update every plugin, find the sessions still on an old build (full recipe)

Loaded on demand by /board (#573). Epic #711 (#712-#715). This verb needs **no GitHub token**: it
only talks to the local `claude` CLI and reads files under `~/.claude` (or `CLAUDE_CONFIG_DIR`).

## Why it exists

A plugin update installs the new build on disk, but a session that is **already open keeps the build it
loaded at startup**. A fix gets published, the user updates, and the problem "persists" in a session that
never saw it. Claude Code has no `plugin update --all`, does not say which open sessions are behind, and
deletes superseded builds only after 14 days.

## Three actions

| Typed | Runs | What it does |
|---|---|---|
| `/board plugins` (or `plugins update`) | `scripts/Update-AllPlugins.ps1` | refresh every marketplace, update every installed plugin, report what changed |
| `/board plugins sessions` | `scripts/Get-PluginSessionMap.ps1` | list open sessions and the plugins each still runs on an old build |
| `/board plugins clean` | `scripts/Remove-OldPluginVersions.ps1` | list (or with `-Execute` delete) old cached builds nobody uses |

Run the script for the action; pass the user's flags through. Never improvise the recipe from this table.

### update

`Update-AllPlugins.ps1` runs `claude plugin marketplace update <m>` for every marketplace in
`known_marketplaces.json`, then `claude plugin update <plugin>@<m>` for every installed plugin of it.
The verdict per plugin comes from **`installed_plugins.json` before vs after**, not from parsing what the
CLI prints:

| Verdict | Meaning |
|---|---|
| updated | version or commit changed; the report shows `old (sha) -> new (sha)` plus a bounded "what's new" from the new build's own CHANGELOG (plugin folder first, then the marketplace checkout; nothing if absent) |
| unchanged | the CLI succeeded and found nothing newer |
| failed | the CLI failed, timed out, or succeeded but the plugin cannot be confirmed in the installed list; the reason is shown |
| skipped | not attempted: its marketplace is no longer registered, it is installed for a project scope only, or **its marketplace failed to refresh** |

A failed marketplace or plugin is **never** reported as up to date, and the exit code is non-zero if any
plugin failed or any git marketplace failed to refresh. A marketplace whose source is a local
**directory** (a development checkout) is refreshed too, but a failure there is only a warning.

Flags: `-DryRun` (print the commands, run nothing), `-Only <plugin|plugin@marketplace>[,...]`,
`-Clean` (afterwards run the cleanup below), `-AcceptMarketplaceCommands`.

`-AcceptMarketplaceCommands` passes `--yes` to `claude plugin update`, which accepts *without asking* a
command the marketplace declares for its install. It is **off by default**; a plugin update that needs
the confirmation fails with that reason instead of hanging (the CLI runs with stdin closed and a
timeout). Offer the flag only for a marketplace the user trusts.

The report ends with how many **open sessions still run old builds** (the session map data) and how many
old builds could be removed. It never deletes on its own.

### sessions

`Get-PluginSessionMap.ps1` prints, for each provably-open session: name, folder, and every plugin it
loaded at a build other than the installed one, `loaded -> installed`, with the fix:

- skills, commands, agents, hooks -> the user types **`/reload-plugins` in that session**. Only the user
  can: it declines when relayed by an agent or Remote Control.
- the plugin ships an MCP server (a `.mcp.json` at its root, or `mcpServers` in its `plugin.json`) -> a
  **new session**; `/reload-plugins` does not reconnect MCP servers. When that cannot be told, the map
  says new session too.

How a session is matched to what it loaded: `sessions/<pid>.json` has the pid and process start time
(`procStart`); each cached build has `.in_use/<pid>` = `{"pid", "procStartFt"}` written by every process
that loaded it. A marker counts for a session only if **pid and start time both match**.

Honesty rules (each is tested):
- **liveness is pid AND start time**, never "the pid exists" (Windows recycles pids). It reuses
  `Test-SessionStartConsistent` from `Board-Work.ps1` (#520/#557), not a second check.
- a session that is not provably open is **never printed** (no name, no folder, no id); sessions whose
  liveness cannot be confirmed are only counted.
- a session with **no marker at all** is `sin datos`, never "al dia": unknown is not fine.
- a plugin is current when the installed build is among the builds the session loaded, so a session that
  reloaded onto the new build reads current.

### clean

`Remove-OldPluginVersions.ps1` — **listing by default**; `-Execute` deletes. A cached build
`cache/<marketplace>/<plugin>/<version>` is removed only when **all** hold, any doubt keeps it:

1. it is not the installed build of any entry in `installed_plugins.json` (by real path, or by
   `plugin@marketplace` + version);
2. no live process holds a marker in it (pid + start time; a stale marker, or a pid reused by a later
   process, does not hold it). A live holder, a holder whose liveness cannot be confirmed, or a marker that
   cannot be read keeps it;
3. its **real path** is strictly inside `<claude home>/plugins/cache/<m>/<p>/` (canonicalised with
   `Get-Item`, so 8.3 short names and `..` cannot defeat it), and neither it nor anything inside it is a
   symlink or junction;
4. it was not touched in the last `-GraceMinutes` (default 60) — an install in progress is not in the
   installed list yet.

If `installed_plugins.json` cannot be read, or is empty, nothing is removed. The deleting function
re-verifies location and links right before it acts; it does not trust the plan. `-ShowKept` prints the
reason for every build that stays.

## The in-session notice (automatic, not typed)

`hooks/hooks.json` registers a `UserPromptSubmit` hook (`scripts/PluginStale-NoticeHook.ps1`). When a
plugin the session loaded has a newer installed build it shows **once per (session, plugin, new build)**,
in plain language, either "type /reload-plugins" or "open a new session (it has MCP servers)". It is silent
otherwise, bounded by a 10 s timeout and its own time budget, swallows its own errors, and always exits 0.
State: `plugin-notices.json` under the shared state directory (`Get-AbiosStateDir -Root $HOME`).

Cost: it runs before every prompt, so it stays nearly free by skipping while `installed_plugins.json`
(the thing an update rewrites) is unchanged since that session's last check, re-checking at most every
30 minutes.

**Honest limit:** only a session that started with a build that already contains this hook can show the
notice (or one that has since run `/reload-plugins`, which loads new hooks). Older sessions are covered by
`/board plugins sessions`.

## Facts this rests on (verified 2026-09-21)

- `/reload-plugins` (Claude Code 2.1.260+) loads new skills, commands, agents and hooks into a running
  session; the user must type it; it does not reconnect plugin MCP servers.
- Updating never affects open sessions. Claude Code deletes orphaned builds after 14 days.
- `autoUpdate` on a marketplace is a per-user setting in `known_marketplaces.json`; a plugin cannot force it.
- Out of scope: restarting or closing sessions for the user.

## Testing rule

The run functions take an injectable runner (`-Runner` on `Invoke-PluginUpdate`) and every script takes a
path root (`-ClaudeHome`); tests use a fake CLI and a fabricated home. **Never run a real `claude plugin update|install|uninstall|marketplace` while
developing or testing this.**
