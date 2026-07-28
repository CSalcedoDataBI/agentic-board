# The expert role catalog

Two files, one effective catalog:

| File | Ships with | Edited by | In git |
|---|---|---|---|
| `presets/roles.json` | the plugin | nobody (upgrades replace it) | plugin repo |
| `.agentic-board/roles.json` | the project | you | **yes** — roles are team knowledge |

> If your project's `.gitignore` excludes `.agentic-board/`, `roles.json` cannot be versioned:
> git **cannot re-include** a file whose parent directory is excluded, so a plain
> `!.agentic-board/roles.json` would be dead config that looks like it works. Exclude the
> directory's *contents* instead:
> ```gitignore
> .agentic-board/*
> !.agentic-board/roles.json
> ```

## Schema

```json
{
  "version": 1,
  "qualityProfile": ["skill-creator", "writing-skills"],
  "roles": [
    { "name": "infra",
      "keywords": ["terraform", "helm", "kubernetes"],
      "skills":   ["iac", "k8s"],
      "agent":    "infra-reviewer",
      "knowledgeDomain": "Infrastructure" }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Identity, and the merge key against the factory catalog. |
| `keywords` | yes | Matched (lowercase, substring) against the plan text to select the role. |
| `skills` | yes | Matched against installed skill **names** — never the plugin namespace — to build the toolset. |
| `agent` | no | An installed agent definition (`agents/*.md`, the same registry the Agent tool resolves). Its body becomes the role's standards. Preferred over `standards`. |
| `standards` | no | Inline prose, for when no agent definition is worth creating. Ignored when `agent` is set. |
| `knowledgeDomain` | no | A domain in `knowledge/registry.json` whose references the expert reads before building. |
| `replace` | no | `true` makes every field replace the factory role's instead of unioning. The way to *remove* factory keywords. |

`qualityProfile` sits at the top level, not inside `roles`: it is engaged for every role and has
no keywords, so it never competes for a match. A local one replaces the factory list wholesale —
that is what lets you shrink it.

## Why `agent` rather than more prose

Claude Code already defines expert personas natively: `agents/*.md`, frontmatter plus a body that
is the system prompt, shipped by plugins and overridable per project. Restating that format inside
a role would duplicate it, so a role **points at** one. Ready-made definitions can be installed
with `/tools` — for instance `wshobson/agents` or `VoltAgent/awesome-claude-code-subagents`
(both unlicensed, so they are referenced and installed, never copied into your repo).

## Merge rules

- Local roles are evaluated **before** factory roles; within each group, file order wins. A merged
  role takes the **local** position — declaring it locally is what places it.
- `keywords` and `skills` **union** with the factory role of the same name, so "we also call it
  `metabase`" does not require redeclaring the role.
- `agent`, `standards`, `knowledgeDomain` and `qualityProfile` **replace** wholesale. Setting
  `agent` locally clears any inherited `standards`, so the two never both apply.

## When it goes wrong

A broken local file never leaves the expert worse off than the factory catalog:

| Condition | Behavior |
|---|---|
| No local file | Factory catalog. Normal, not a warning. |
| Invalid JSON, or an unknown `version` | Warn; continue with the factory catalog. |
| A role missing `name`, `keywords` or `skills` | Warn; skip **that role only**. |
| Duplicate `name` in the local file | Warn; the last declaration wins. |
| `agent` names something not installed | Warn; the role survives and falls back to `standards`, then to the generic paragraph. |
| `knowledgeDomain` names a missing domain | Warn; the role survives without the knowledge line. |
| The shipped preset is missing | Hard error — that is a broken install, not a misconfiguration. |

Every warning goes to the warning stream, never to stdout: `config` and `roles list` have parsed
output.

Run `/board expert roles why "<plan text>"` to see exactly which keyword decided a match, and
`/board expert roles` to see which roles hook zero skills.
