# /board cerrar-ciclo — classify and route the current branch (full recipe)

Loaded on demand by /board (#573).

- **cerrar-ciclo** (close-the-loop) — classify the CURRENT branch and route it to its next
  disposition by running `scripts/Board-Work.ps1 -CloseLoop` (repo from origin, or `-Repo`). It is
  NOT "merge": merging has the review gate, and "cerrar ciclo" is ambiguous ("ship it" vs "stop for
  today"), so it only ever PROPOSES the next command and performs exactly ONE action — the
  single-session teardown of a proven-merged local branch (the gap the fleet's `-Sessions -Watch
  -AutoClean` never reaches for an interactive session). States it detects on the current branch:
  - **uncommitted changes** → stop; commit or `handoff -Save` (decided BEFORE any PR state, so work is never lost);
  - **commits, no PR** → `New-BoardPR`; **PR open** → `Board-ReviewGate` (merge if it passes, `handoff -Save` if not);
  - **PR merged, branch alive** → the gap: switches to the default branch, `git branch -D` the merged branch
    (squash-merge means `-d` refuses; a proven merge licenses `-D`), and prunes the session-registry entry —
    with confirmation (`-Force` to skip, `-DryRun` to preview). Never on a dirty tree;
  - **PR closed unmerged** → decide: reopen/rescue or discard.
  It operates on the current branch/session only — the repo-wide sweep is `/board doctor`.
  `Board-Merge` now also NOTES when its `--delete-branch` left the local branch behind and points here.
