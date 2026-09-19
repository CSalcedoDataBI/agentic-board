# /board changelog — generate the version block (full recipe)

Loaded on demand by /board (#573).

- **changelog** — generate a Keep-a-Changelog version block from the board's Done issues by
  running `scripts/Board-Changelog.ps1 -ProjectNum <n>`. Groups issues into Added/Changed/Fixed
  by the board Type field (Feature→Added, Bug→Fixed, Docs/Refactor/Chore→Changed; label fallback).
  Includes an issue only when it is closed, was NOT closed as "not planned"/duplicate, was closed
  **by a merged PR** whose merge is on/after the last CHANGELOG entry (`closedByPullRequestsReferences`),
  is not already cited — as `(#n)` **or inside a range** such as `#423–#430` — and has a Type or
  label that says which heading it goes under (there is no default heading; an unclassified issue
  is never filed under `### Added`). Every closed issue that is left out because of the PR rule or
  the missing classification is printed with its reason, so you can place it by hand: the generator
  proposes candidates, it does not take over the curation of `[Unreleased]` (#676). Prints the
  block; `-Write` inserts it at the top of CHANGELOG.md; `-Version`/`-Date`/`-Since` override the
  defaults (version read from plugin.json). Pre-existing prose entries without a number are not
  recognized, so review the first generated block before `-Write`.
  The release cut (`New-Release.ps1`) also checks the **bump** against `[Unreleased]`: only
  `### Fixed`/`Security` → at least patch; any `Added`/`Changed`/`Deprecated`/`Removed` (or an
  unknown header) → at least minor; a `BREAKING` marker → major (minor while the version is 0.x). A
  smaller bump is refused before anything is written; a larger one only warns. `-Check -Bump <x>`
  judges a planned bump without writing.
  For releasing a **BI artifact** (a model/report, not this plugin), the changelog is one step of the
  full release definition-of-done — see `references/bi-release-checklist.md` (M4.1): what the review
  gate enforces (BPA + TMDL-breaking), what stays external to Fabric (deployment, refresh), and what a
  human confirms (renders, rollback).
