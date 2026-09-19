# /board triage — evidence fields + proposed Priority (full recipe)

Loaded on demand by /board (#573).

- **triage** — fill an item's triage fields from EVIDENCE and PROPOSE its Priority, via
  `scripts/Board-Triage.ps1` (#306). Not a bulk default — a uniformly-filled board looks prioritised
  without being so; the point is grounded values, not absence of blanks.
  - **`-Pending`** lists the pending items and which of Type/Area/Estimate/Priority are blank — the
    work-list to triage (the board's `Size` equivalent is **Estimate**; there is no Size field).
  - **Type / Area / Estimate are evidence fields.** YOU infer them from the issue's own content — the
    kind of failure (Type), the files/surface it touches (Area), the change size its Scope implies
    (Estimate) — and write them directly: `Board-Triage.ps1 -Issue <n> -Type <t> -Area <a> -Estimate <n>`.
  - **Triage a backlog in ONE call, not one call per issue (#605).** Every invocation reads the whole
    board, so a loop of `-Issue <n>` calls re-pays that read per issue and exhausts the GraphQL quota
    around the 8th-9th issue of a 300-item board. Hand the whole set to one invocation and the board
    is read once: `-Issues 42,43,44 -Type Bug -Area scripts` (same values for all), or
    `-BatchFile triage.json` — a JSON array `[{"issue":42,"type":"Bug","area":"scripts","estimate":3,
    "priority":"P2","rationale":"..."}, ...]` (only `issue` is required; `repo` qualifies a bare number
    on a multi-repo board). Every entry is validated before the first write, so a bad row 40 of 45
    refuses the batch instead of leaving it half-done (before any gh call, board resolution included);
    a target that cannot be resolved is listed at the end as "Pendientes para reintentar" (exit 1) while
    the rest are still triaged, but a failed WRITE (API/auth/quota) stops the batch and lists every
    entry not yet done. Any `-Issues`/`-BatchFile` run is a batch, even with a single entry. `-ProjectNum`
    is accepted as an alias of `-Number`, like everywhere else in the suite (#511).
  - **Priority is a business judgement NOT in the repo.** PROPOSE P0–P3 with a one-line rationale per
    issue and let the user confirm in a batch: `-Priority P2 -Rationale '...'` PRINTS the proposal and
    writes nothing; only `-ConfirmPriority` writes it. The script REFUSES `-Priority` with no
    `-Rationale`. Never write Priority silently — a well-argued autonomous guess is still your opinion
    wearing the owner's name.
  - Do this when you START an issue (step 4 below) and when you CREATE issues (`/board plan`), so no
    item lands with an empty Type/Area/Estimate; use `-Pending` to backfill the existing backlog.
