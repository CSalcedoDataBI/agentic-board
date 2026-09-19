# /board telemetry — the field sweep (full recipe)

Loaded on demand by /board (#573).

- **telemetry** — measure how the tool ACTUALLY behaved across the user's real sessions, by running
  `scripts/Invoke-FieldScan.ps1`. Distinct from `doctor` (which audits this repo's branches) and
  from `field` (which fills board columns): this reads local session transcripts and reports where
  agentic-board helped and where it got in the way.
  - **Incremental by watermark, never a `scanned` flag.** The ledger records how far each session
    was read (events + bytes), so "new work" means new sessions *and* grown ones, and only the
    unread tail is parsed. A boolean would retire a session permanently on first read and silently
    lose everything appended later.
  - **Two stages.** A deterministic extractor (no model) turns hundreds of megabytes into a few
    hundred candidate episodes; only those are worth a model's attention.
  - **Four signals**, each mechanical: **repetition** (the same action script re-invoked — resolvers
    and wrappers are exempt, since re-invoking those is their contract), **abandonment** (a failure
    followed by the same job done with bare `gh`/`git` — the most valuable and the most invisible),
    **correction** (the user reverses what just happened), and **silence** (a failure that went
    nowhere at all).
  - **Read-only** over the transcript store; everything it writes goes to a machine-level field root
    OUTSIDE any repo, so the local record cannot be committed. **Nothing is filed automatically** —
    it produces candidates for a human to judge.
  - `-WhatIf` shows what would be read without touching anything; `-Limit <n>` bounds a first run.
  - **`-MatchFiled` — recurrence vs new (#476).** After the sweep, each script that had incidents (a
    failed invocation or any signal) is joined, by name, to the issues already filed about it on
    `-Repo` (default the tool's own; open ones plus those closed in the last `-ClosedDays`, default
    90). The report then separates **reincidencia (ya archivado)** - the defect is known, here is how
    many more incidents the sweep saw and which issues name it - from **candidatos NUEVOS** - nothing
    filed names that script. It reads GitHub (read-only) and files nothing; a failed read is reported
    and the sweep result is still printed. `-CandidatesFile <json>` matches against a local list
    instead (offline). The matching is the same code the feedback skill uses before filing
    (`scripts/IssueSearch.ps1`). Only sessions swept in THIS run count: a second run that finds
    nothing new has no recurrence to report.
