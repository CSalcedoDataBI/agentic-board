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
  **Before running the script, search for prior art** — this is a gate, not a suggestion:
  run `gh search repos <topic> --sort=stars --limit=10` and `gh search code <pattern>` to find
  existing tools or approaches. Record what you found (queries, candidates, stars/license/adoption,
  decision: build / reference / extend) and pass it via `-PriorArt "<block>"`. If the work is
  genuinely novel and no search makes sense, pass `-NoPriorArt` instead — the skip is written into
  the epic body so the omission is visible rather than invisible (same shape as `-Rationale` in
  `/board triage`). The script throws if neither is supplied.
  Then run `scripts/Board-Plan.ps1 -Title "plan: <feature>" -Tasks "A","B",... -Description "..." -PriorArt "<block>"`
  — it ensures plan/plan-task labels, creates the epic (with the prior-art block in the body), reuses Board-Breakdown for NATIVE
  Optionally enrich the epic with the four standard items the **`/board expert`** auto-mode
  reads: `-Research "<prior-art / docs found>"`, `-RoleSeed "<expert role objective>"`,
  `-Deliverables "d1","d2"`, `-TestPlan "DoD1","DoD2"` (here `-Description` becomes the Goal).
  Any omitted section renders a `_TBD - fill before /board expert auto_` placeholder, so a plan
  can be created now and completed before running the expert. All four are optional — with none,
  the epic body is rendered exactly as before.
  sub-issues, resolves the repo board with Resolve-Board (never a duplicate), and registers
  epic + children. Suggest `/board fill` for Priority/Size/Type and `/board work` to start the
  first task. Issues are created ONLY in the current repo (origin) — never elsewhere.
