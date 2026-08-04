# /board changelog — generate the version block (full recipe)

Loaded on demand by /board (#573).

- **changelog** — generate a Keep-a-Changelog version block from the board's Done issues by
  running `scripts/Board-Changelog.ps1 -ProjectNum <n>`. Groups issues into Added/Changed/Fixed
  by the board Type field (Feature→Added, Bug→Fixed, Docs/Refactor/Chore→Changed; label fallback).
  Includes only issues closed since the last CHANGELOG entry AND not already cited as `(#n)` —
  so shipped work is never double-listed. Prints the block; `-Write` inserts it at the top of
  CHANGELOG.md; `-Version`/`-Date`/`-Since` override the defaults (version read from plugin.json).
  NOTE: the dedup keys on `(#n)` citations, which this tool always emits — pre-existing prose
  entries without a number are not recognized, so review the first generated block before `-Write`.
  For releasing a **BI artifact** (a model/report, not this plugin), the changelog is one step of the
  full release definition-of-done — see `references/bi-release-checklist.md` (M4.1): what the review
  gate enforces (BPA + TMDL-breaking), what stays external to Fabric (deployment, refresh), and what a
  human confirms (renders, rollback).
