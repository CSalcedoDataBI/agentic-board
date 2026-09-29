---
name: cleanup-ops
description: Engine behind /cleanup - machine housekeeping for Claude Code, kept apart from GitHub board work. Sweep every session of a repo (park unmerged work as draft PRs, archive resolved sessions), compress old session transcripts into an indexed archive and restore them, free disk from duplicate compaction copies and old plugin builds, and update every installed plugin. Plan first, act only on a confirmation. Routed by the cleanup command; never typed directly. Triggers — "/cleanup", "limpia las sesiones", "archiva las sesiones viejas", "libera espacio", "limpia el disco", "comprime los transcripts", "actualiza los plugins", "clean up my sessions", "free disk space".
user-invocable: false
---

# cleanup-ops — machine housekeeping (sessions · transcripts · disk · plugins)

`/board` administers GitHub: issues, the board, PRs. What fills a MACHINE is a different job, so it
has its own command. This skill is its engine. Every verb:
- **plans first and writes nothing**, then acts only on one explicit confirmation (`--force` /
  `-Execute`);
- **never touches** a session that is running, a session the app still shows (for transcripts), or
  a repo other than the current one (for sessions), unless the user asks for a wider scope;
- speaks through the agent, which reports in the user's language.

| Verb | Contract | Script |
|---|---|---|
| `/cleanup sessions` (this repo; `-Scope orphans` / `all`) | `references/verbs-sessions.md` | `Cleanup-Sessions.ps1` |
| `/cleanup transcripts` (`find`, `restore`) | `references/verbs-transcripts.md` | `Cleanup-Transcripts.ps1` |
| `/cleanup disk` | `references/verbs-disk.md` | `Cleanup-Disk.ps1` |
| `/cleanup plugins` (`sessions`, `clean`) | `references/verbs-plugins.md` | `Update-AllPlugins.ps1`, `Get-PluginSessionMap.ps1`, `Remove-OldPluginVersions.ps1` |

A sensible order when the machine is full:
1. `sessions` in each repo, and once with `-Scope orphans`. This archives what is resolved.
2. `transcripts`, which can now compress the transcripts of the sessions just archived.
3. `disk`, which cleans duplicate compaction copies, old plugin builds and stale state.
