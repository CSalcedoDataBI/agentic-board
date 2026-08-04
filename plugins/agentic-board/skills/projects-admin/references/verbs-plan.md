# /board plan — turn a plan into epic + sub-issues (full recipe)

Loaded on demand by /board (#573).

- **plan** — turn a plan into a tracked epic + native sub-issues on the board. A plan is NOT
  done when a markdown file is written — it is done when its tasks are issues. Two entry modes
  (ask which one if unclear):
  1. **Plan now (interactive):** gather the goal and the SUBSTANTIAL tasks conversationally
     (tiny steps stay as checkboxes in the epic description, not issues). Show the proposed
     epic title + task list and WAIT for the user's approval.
  2. **Plan exists:** read the plan document (or plan-mode output) the user points to, extract
     goal + substantial tasks, show the same proposal, and WAIT for approval. Link the doc in
     the description ONLY as a full `https://github.com/<owner>/<repo>/blob/<branch>/<path>`
     URL on a PUSHED ref — relative paths render broken in issues.
  Then run `scripts/Board-Plan.ps1 -Title "plan: <feature>" -Tasks "A","B",... -Description "..."`
  — it ensures plan/plan-task labels, creates the epic, reuses Board-Breakdown for NATIVE
  Optionally enrich the epic with the four standard items the **`/board expert`** auto-mode
  reads: `-Research "<prior-art / docs found>"`, `-RoleSeed "<expert role objective>"`,
  `-Deliverables "d1","d2"`, `-TestPlan "DoD1","DoD2"` (here `-Description` becomes the Goal).
  Any omitted section renders a `_TBD - fill before /board expert auto_` placeholder, so a plan
  can be created now and completed before running the expert. All four are optional — with none,
  the epic body is rendered exactly as before.
  sub-issues, resolves the repo board with Resolve-Board (never a duplicate), and registers
  epic + children. Suggest `/board fill` for Priority/Size/Type and `/board work` to start the
  first task. Issues are created ONLY in the current repo (origin) — never elsewhere.
