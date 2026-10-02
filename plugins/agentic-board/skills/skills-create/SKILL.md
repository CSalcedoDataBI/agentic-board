---
name: skills-create
description: "Engine behind /skills create and improve: build or raise a skill end to end (prior art, author, pressure test, audit gate, trigger eval). Triggers — \"crea una skill\", \"mejora esta skill\"."
user-invocable: false
disable-model-invocation: true
---

# skills-create - one pipeline for a new skill or a better one

The pieces already exist: `skill-creator` writes, `writing-skills` pressure-tests, `skills-audit`
finds what is wrong, `skill-improver` fixes it. What was missing is the order, the checks before
writing, and a gate that says "done". `scripts/Skill-Pipeline.ps1` owns the deterministic parts.

## /skills create <name> "<what it should do>"

1. **Plan** (read-only):
   `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Skill-Pipeline.ps1" -Mode create -Name <name> -Description "<draft trigger text>" [-Topic "<search words>"]`
   It prints the toolkit status, overlapping installed skills, public prior art (stars, last push,
   license), the proposed scope with its reason, the target folder, and the stages.
2. **Stop and ask when the plan says so**, in the user's language:
   - toolkit missing -> offer `/skills bootstrap quality` first;
   - a strong overlap -> recommend `/skills improve <that skill>` instead of a near-duplicate;
   - a good public skill -> recommend installing it (`Install-SkillFromRepo.ps1`, keeps its LICENSE)
     instead of writing one;
   - confirm the scope: this repo's `.claude/skills` (about this repo) or `~/.claude/skills`
     (everywhere).
3. **Author** with the `skill-creator` skill, writing straight into the target folder. The
   description is third person, starts with the use case, and names its triggers and when NOT to use it.
4. **Pressure test** with the `writing-skills` skill: run a realistic task WITHOUT the skill first
   and record how it fails (RED); then WITH it (GREEN). No RED, no skill: if nothing fails without
   it, it is not needed.
5. **Audit/improve loop**: `Skill-Pipeline.ps1 -Verify -Name <name>`. While it exits non-zero, fix the
   blocking findings with the `skill-improver` skill and run it again. Low findings are advisory.
6. **Trigger eval** with the `skills-audit` runtime eval (`${CLAUDE_PLUGIN_ROOT}/skills/skills-audit/SKILL.md`) (enabled vs disabled, 3 runs): it must fire
   on its own prompts and stay quiet on near-misses. A miss goes back to step 5 on the description.
7. **Report**: where it lives, the RED/GREEN evidence, the audit result, the trigger-eval score.

## /skills improve <name>

1. `Skill-Pipeline.ps1 -Mode improve -Name <name>`: toolkit, where it lives, the stages.
2. `Skill-Pipeline.ps1 -Verify -Name <name>` lists what blocks it.
3. Improve loop with `skill-improver` until `-Verify` passes.
4. Pressure test: the behavior the skill exists for must still pass. Change the skill, not the test.
5. Trigger eval, then report the before/after findings.

## Rules
- Never overwrite a skill you did not create in this run without the user's yes. `improve` edits in
  place: show the diff before saving.
- A third-party skill (plugin cache, cloned toolkit) is improved upstream, not in place: file the
  finding with `skills-audit` filing, which routes it to the owner's repo.
- The pipeline never publishes, pushes or opens PRs on its own. A project-scope skill is a change
  to that repo: commit it like any other change.
