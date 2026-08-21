# /board cerrar-ciclo — classify and route the current branch (full recipe)

Loaded on demand by /board (#573).

- **cerrar-ciclo** (close-the-loop) — classify the CURRENT branch and PERFORM its next
  disposition by running `scripts/Board-Work.ps1 -CloseLoop` (repo from origin, or `-Repo`). It is
  NOT "merge": merging has the review gate, and "cerrar ciclo" is ambiguous ("ship it" vs "stop for
  today") — that one step stays a human decision. Every other step it takes itself instead of
  printing a command to copy-paste (#650), asking a plain-language question first only where a
  genuine choice exists. States it detects on the current branch, and what it does about each:
  - **uncommitted changes** → asks "guardo un handoff?" (s/n); on yes, runs `Board-Handoff -Save`
    for you (decided BEFORE any PR state, so work is never lost to a later step);
  - **commits, no PR** → opens the PR itself, no question (reversible — you can close it again);
  - **PR open** → runs `Board-ReviewGate` itself and prints its result; merging (if it passes) stays
    the human's call, same as any other PR;
  - **PR merged, branch alive** → the gap: switches to the default branch, `git branch -D` the merged
    branch (squash-merge means `-d` refuses; a proven merge licenses `-D`), and prunes the
    session-registry entry — with confirmation (`-Force` to skip, `-DryRun` to preview). Never on a
    dirty tree;
  - **PR closed unmerged** → asks reopen-or-discard in plain terms (discarding here throws away
    UNMERGED work, unlike the merged case above — the question says so explicitly, with a second
    confirmation before deleting).
  It operates on the current branch/session only — the repo-wide sweep is `/board doctor`.
  `Board-Merge` now also NOTES when its `--delete-branch` left the local branch behind and points here.
