---
name: cleanup-ops
description: "Engine behind /cleanup: machine housekeeping — sessions, transcripts, disk, plugin updates. Plans first, acts on one confirmation. Triggers — \"limpia las sesiones\", \"libera espacio\", \"actualiza los plugins\", \"clean up my sessions\"."
user-invocable: false
disable-model-invocation: true
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
