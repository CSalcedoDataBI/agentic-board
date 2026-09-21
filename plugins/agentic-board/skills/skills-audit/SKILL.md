---
name: skills-audit
description: Use to evaluate Agent Skills and detect when one is failing — a static health audit (empty/first-person/over-budget descriptions, missing triggers, near-duplicates, misplaced) plus an on-demand runtime trigger-eval (run a realistic prompt with the skill enabled vs disabled, 3x, score false positives/negatives). Classifies failures (under-triggered, over-triggered, wrong output, ignored, obsolete) and, behind a human gate, files a SANITIZED issue to the repo that OWNS the skill — the tool's own board for its skills, the project's board for the project's own skills, local-only for third-party — never leaking the private project you are working in. Triggers — "audita mis skills", "esta skill no dispara/falla", "evalúa el triggering", "skill health check", "por qué no se activó la skill", /skills audit.
user-invocable: false
---

# skills-audit — detect skill failures, file them where they belong

Part of the **skills-ops** module. Reuses `gh-account` (token), the `abios-feedback`
sanitize-then-file discipline, `projects-admin` (issue + board), and the
`guard-no-private.ps1` backstop. See `references/filing.md` for the filing recipe.

## Step 1 — Static audit (deterministic)

```powershell
$audit = & "${CLAUDE_PLUGIN_ROOT}/scripts/Invoke-SkillAudit.ps1" -Root . -Scope all
$audit.summary; $audit.findings | Format-Table severity,type,skill,filing
```

The overlap pass compares distinct skills, not copies: the same skill seen through the repo tree,
the plugin cache and worktrees is folded into one (`summary.copiesCollapsed` says how many were
folded, and a `near-duplicate` finding says when it stands for several copies with the same description; the audit compares descriptions, so two copies whose bodies differ but whose descriptions match are folded). Two
copies of one name with DIFFERENT descriptions are a real `divergent-copy` finding (a stale copy).

A wording defect (`no-triggers`, `first-person`, `over-budget`, `no-when-not`, `empty-description`) is
reported ONCE per skill, not once per copy: copies with the same name, the same description and the
same owner are one finding, which carries `copies` and `paths` (local evidence: never paste the paths
into a filed issue). `summary.perCopyFindingsFolded` says how many findings that saved. A copy whose
description differs keeps its own findings, and per-file defects (`missing-name`, `misplaced`) stay per file.

Ownership comes from the plugin's OWN manifest (`.claude-plugin/plugin.json`, else the marketplace
entry), never from a path segment (that segment is the marketplace name in the installed cache
and the word `marketplaces` in a marketplaces clone). A plugin is the tool's only if its name AND its
declared repository/homepage are the tool's; an unknown, unreadable or unverified plugin is
`filing = local` (`ownerRepo` is an `owner/repo` or empty, never a name). Nothing is filed on a guess.

Findings carry a `filing` route (`file` = open an issue on the owner repo; `local` =
report only). This is `Resolve-SkillOwner` deciding where each finding belongs — the tool's
board for agentic-board skills, the project's board for project skills, local-only for
third-party/personal (never open issues in someone else's repo).

## Step 2 — Runtime trigger-eval (on-demand, agentic)

The static pass cannot tell if a skill actually *fires*. For a suspect skill, run the
enabled-vs-disabled baseline — the core test:

1. Pick 3+ realistic prompts that SHOULD trigger the skill (and a couple that should NOT).
2. Toggle the skill with `skillOverrides` in `.claude/settings.local.json`
   (`"skill-name": "off"` to disable, remove to enable). Run each prompt **3×** per state.
3. Score:
   - **under-triggered** — enabled state shows no behavior change / you had to invoke it by hand.
   - **over-triggered** — fires on the should-NOT prompts (false positive).
   - **wrong-output** — fires but the result fails the expected behavior.
   - **ignored** — a bundled reference file never gets read.
   - **obsolete** — the base model passes WITHOUT the skill loaded → candidate for retirement.
4. Append each as a finding (same shape as Step 1) with the failure type and the verbatim
   evidence (the prompt + what happened).

> Guardrail: never rewrite a skill purely from the agent's own reasoning without review —
> that is the documented self-improvement drift risk. Findings feed a human decision.

## Step 3 — File it (SANITIZED, behind the human gate)

For each `filing = file` finding, follow `references/filing.md`: abstract away all private
context, show the user the exact sanitized issue, get an explicit yes, then create it on the
owner repo's board. `filing = local` findings are reported in-session only — hand them to the
user to file upstream themselves.

**Never** file skill-audit issues to the private project you are working in. **Never** include
data values, client names, GUIDs, paths, tokens, or screenshots — the public file path, the
wrong behavior, and a generic repro only. The `guard-no-private.ps1` pre-commit/pre-push guard
is the backstop, not a substitute for the abstraction step.

## Verification checklist
- Each `file` finding routed to the OWNER repo (not the current project)?
- Sanitized: no private data; generic repro; public path only?
- Human approved the exact issue text before it was created?
- Runtime-eval findings include verbatim evidence and a failure type?
