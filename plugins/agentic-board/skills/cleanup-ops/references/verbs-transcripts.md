# /cleanup transcripts — compress old session transcripts, restore them byte for byte (full recipe)

Loaded on demand by /board (#736).

Every Claude Code session writes `~/.claude/projects/<project>/<sessionId>.jsonl`, plus a companion
`<sessionId>/` folder of tool results and subagents. Nothing removes them, so they fill the disk.
This verb runs `scripts/Cleanup-Transcripts.ps1`. It needs no GitHub token.

**Recipe:**

1. **Plan** (writes nothing): `Cleanup-Transcripts.ps1`. Show the user:
   - the total size;
   - what each age threshold would free (7 / 14 / 30 / 60 / 90 days — only what may be compressed);
   - why the rest is kept.
2. **One confirmation** with the chosen threshold, e.g. "compress the 31 transcripts that are 30 days
   or older, 295 MB?". Then run `Cleanup-Transcripts.ps1 -Force` (add `-OlderThanDays <n>` for another
   threshold, and `-ArchiveDir <folder>` to keep the archive on another drive).
3. **Report:**
   - how many were compressed and how much was freed;
   - any that failed, by id and reason;
   - how to find and restore one.
4. **Find:** `Cleanup-Transcripts.ps1 -Find <text>` searches the index (title, folder, branch, id).
5. **Restore:** `Cleanup-Transcripts.ps1 -Restore <sessionId>` puts the transcript and its companion
   folder back exactly where they were. It verifies the SHA-256 before dropping the zip, and never
   overwrites a transcript that exists again at that path.

**What may be compressed** (all required, `Get-TranscriptVerdict`):
- it is older than `-OlderThanDays` (default 30) by its last write;
- it is not the transcript of a running session (`~/.claude/sessions`, process id + start time;
  "cannot tell" counts as running);
- the desktop app does **not** still show it. The app keeps one metadata file per session under
  `%APPDATA%\Claude\claude-code-sessions\...\local_*.json` with its `cliSessionId` and `isArchived`.
  This file is read-only here. A transcript whose app session is not archived is never touched,
  because the sidebar would keep a session that no longer opens. Archive the session first with
  `/cleanup sessions`. If some of those metadata files cannot be read, an unmapped desktop
  transcript is kept.

**Where it goes:** `<ArchiveDir>/<project>/<sessionId>.zip` (default `~/.claude/transcript-archive`),
indexed in `<ArchiveDir>/index.jsonl`. Each index row holds:
- session id, original path and zip path;
- title (from the app when known, else the transcript's custom title) and host session id;
- folder, branch, issue (from an `issue-<n>` branch) and entrypoint;
- first/last activity;
- original and zipped size, SHA-256, and when it was archived.

The index is rewritten after every transcript, so an interrupted run never leaves an unindexed zip.

**Safety:**
- The original is deleted only after the zip has been read back and its transcript hashes the same.
  If the check fails, the zip is dropped and the original kept.
- Restoring refuses to overwrite. It is guarded three times: the transcript path check, the per-file
  check, and .NET's own no-overwrite.
- Nothing here deletes an archive; `-Restore` removes a zip only after a verified restore.

**Known limit:** each project folder has a `sessions-index.json` cache that Claude Code maintains. It
is not edited, so it may keep listing a compressed session until Claude Code refreshes it. Resuming a
compressed session needs `-Restore` first.
