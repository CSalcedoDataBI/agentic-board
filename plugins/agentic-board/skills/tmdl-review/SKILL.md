---
name: tmdl-review
description: "Use when asked whether a Power BI or Fabric TMDL model change is safe to merge: diffs *.tmdl between a PR or two refs and classifies each change BREAKING, WARNING or INFO. Not for writing or editing TMDL/DAX, or for best-practice (BPA) rule checks. Triggers — \"revisa el diff TMDL\", \"¿este cambio rompe el modelo?\", \"review the TMDL diff\", \"is this model change safe to merge\"."
user-invocable: false
---

# tmdl-review — detect breaking semantic-model changes

PBIP repos store the Power BI / Fabric semantic model as **TMDL** (`*.tmdl`) text
files. A diff over those files is hard to read by eye: a dropped column, a changed
`dataType`, or a deleted measure will break downstream reports, DAX, and refreshes,
but looks the same in raw text as a harmless display-folder rename.

`scripts/Tmdl-DiffReview.ps1` parses the model before/after a change and classifies
every schema change by severity.

## When to use

- A PR edits `*.tmdl` and you need to know whether it is safe to merge.
- Before opening a PR, to self-check your own model change.
- As part of `/board work` step 5 — `Board-ReviewGate.ps1` runs this automatically
  when the PR touches `*.tmdl` (warn-only; it does not change the gate verdict).

## Two modes

**PR mode** (no local clone needed) — reads the PR's changed `*.tmdl` via the GitHub
API, fetching base and head content by ref:

```powershell
$env:GH_TOKEN = (& "${CLAUDE_PLUGIN_ROOT}/scripts/Get-GhAccount.ps1").Token   # see gh-account
& "${CLAUDE_PLUGIN_ROOT}/scripts/Tmdl-DiffReview.ps1" -Repo <owner/name> -PR <n>
```

**Local mode** — diffs `*.tmdl` with git in the current working copy:

```powershell
& "${CLAUDE_PLUGIN_ROOT}/scripts/Tmdl-DiffReview.ps1" -Base main -Head HEAD
```

## Severity rules

| Severity | Change |
|---|---|
| **BREAKING** | table / column / measure / hierarchy / relationship / role **deleted**; column `dataType` changed; column `sourceColumn` changed; column/measure **renamed** |
| **WARNING** | measure / partition-source expression changed; column `summarizeBy` changed; object becomes hidden; relationship `crossFilteringBehavior` changed |
| **INFO** | any **addition**; `formatString` / `displayFolder` / `description` / `lineageTag` changes |

A delete + add of the same kind under the same parent, with identical signature
(column `dataType`+`sourceColumn`, or measure expression), is reported as
**RENAMED** (breaking — references by name break) rather than an unrelated pair.

## Flags

- `-FailOnBreaking` — exit 1 when any BREAKING change is found (default: warn only,
  exit 0). The M3.3 hard merge-block uses this: `Board-ReviewGate.ps1` runs the TMDL review
  with `-FailOnBreaking` (alongside `Bpa-GateReview.ps1 -FailOn error`) and blocks the merge
  when either finds a problem in a PR that touches the model (#16).
- `-Json` — emit the findings object as JSON instead of the colored report.

## Limits (v1, honest)

- The comparison is **per file**: only changed `*.tmdl` are compared. A cross-file
  effect (a relationship in an unchanged file referencing a column dropped in a
  changed file) is caught only if both files changed.
- The parser is pragmatic and line-based (indentation), not a full TMDL grammar.
  Calculation groups, perspectives, translations, and role filter expressions are
  not diffed in detail. Table/column/measure/hierarchy/partition/relationship/role
  existence and the key breaking properties are covered.
