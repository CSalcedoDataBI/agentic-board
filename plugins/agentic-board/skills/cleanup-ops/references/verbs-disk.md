# /cleanup disk — one report of what fills the disk, one --force that cleans what is provably safe (full recipe)

Loaded on demand by /cleanup (#737). Runs `scripts/Cleanup-Disk.ps1` and needs no GitHub token.

**Recipe:**
1. **Plan** (writes nothing): `Cleanup-Disk.ps1`. Tell the user what each of the four items would free,
   and list the big folders that are **not** this tool's to touch.
2. **One confirmation**, then `Cleanup-Disk.ps1 -Force`.
3. **Report** what was freed, and anything that failed with its reason.

**What `-Force` cleans:**

| Item | Rule |
|---|---|
| Compaction copies (`~/.claude/compact-snapshots/**`, this repo's `.agentic-board/compact-snapshots/`) | See "Compaction copies" below. |
| Old plugin builds | Exactly `/cleanup plugins clean -Execute`: `Get-VersionCleanupPlan` + `Invoke-PluginCleanup`, re-verified right before deleting. |
| This repo's `.agentic-board/` state | Exactly `Clear-AbiosState.ps1 -Force`: briefings, logs and markers past their age. Durable records are never touched. |
| Session transcripts | **Reported only.** They have their own verb, their own confirmation and a restore path: `/cleanup transcripts`. |

**Compaction copies.** The old PreCompact hook copied the whole transcript on every compaction. It now
writes a one-line marker instead (#737). A copy is deleted only in one of two cases:
- the original transcript still exists, starts with the same bytes and is at least as long;
- the original transcript was compressed into the transcript archive and covers the copy.

Otherwise the copy may be the last one, and it is kept.

Folders it measures but never touches (e.g. a third-party `markitdown-venv`) are listed under "not
this tool's", so the user knows where the rest of the space went.
