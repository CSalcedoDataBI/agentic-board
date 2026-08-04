# /board handoff — save/resume cross-session context (full recipe)

Loaded on demand by /board (#573). Design doc: references/handoff.md.

- **handoff** — save or resume a curated cross-session context, so work can continue in a fresh
  session days later (even on another machine), via `scripts/Board-Handoff.ps1`. Full design in
  `references/handoff.md`. Parse `save` vs `resume` from the request (default: if a
  `[abios-handoff]` comment / local `HANDOFF.md` exists and little was done this session, offer
  **resume**; otherwise **save**).
  - **save** — compose the curated, [V]/[?]-tagged content (next step / done / open threads /
    traps / key files) yourself, verifying each claim live, then run
    `scripts/Board-Handoff.ps1 -Save -NextStep "..." -Done "...","..." -Traps "..." -KeyFiles "..."`.
    It autofills the frontmatter from git + `.agentic-board/sessions.json`, writes a gitignored
    `HANDOFF.md`, archives the previous one, upserts the durable `[abios-handoff]` comment on the
    linked issue, and drops a MEMORY.md pointer (opt-out `-NoMemo`). `-DryRun` previews.
    - **No linked issue?** The durability comes from the issue (the portable `[abios-handoff]`
      comment + the memo). With none resolved (no active session, not on an `issue-<n>` branch),
      `-Save` now **refuses** instead of silently degrading to a gitignored local-only file with no
      memo. OFFER the user the choice: link it with `-Issue <n>` (the next pending is shown by
      `/board work`) — portable + auto-surfaced — or accept a deliberate machine-local handoff with
      `-Local`. Do not just pass `-Local` for them; a local-only handoff is not portable.
  - **resume** — `scripts/Board-Handoff.ps1 -Resume` reads the latest `[abios-handoff]` comment
    (falls back to local `HANDOFF.md`), rehydrates, reports branch/PR drift, carries traps
    forward, clears the consumed pointer, and offers to start the linked issue. TREAT the printed
    handoff as the session briefing and continue that work.
  - **auto-load on resume** (opt-in): `references/handoff-hook.md` wires a SessionStart hook so a
    resumed session surfaces the handoff automatically.
  - **heavy memory** (opt-in, security-gated): for persistent *semantic* memory across projects,
    `scripts/Suggest-HeavyMemory.ps1` proposes installing Basic Memory (upstream, AGPL) — never
    vendored. See `references/heavy-memory.md`. The default remains the lightweight `HANDOFF.md`.
