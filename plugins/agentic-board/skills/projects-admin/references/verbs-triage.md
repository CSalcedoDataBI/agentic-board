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
  - **Priority is a business judgement NOT in the repo.** PROPOSE P0–P3 with a one-line rationale per
    issue and let the user confirm in a batch: `-Priority P2 -Rationale '...'` PRINTS the proposal and
    writes nothing; only `-ConfirmPriority` writes it. The script REFUSES `-Priority` with no
    `-Rationale`. Never write Priority silently — a well-argued autonomous guess is still your opinion
    wearing the owner's name.
  - Do this when you START an issue (step 4 below) and when you CREATE issues (`/board plan`), so no
    item lands with an empty Type/Area/Estimate; use `-Pending` to backfill the existing backlog.
