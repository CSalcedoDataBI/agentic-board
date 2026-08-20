# The expert role catalog

Three files, one effective catalog:

| File | Ships with | Edited by | In git | Scope |
|---|---|---|---|---|
| `presets/roles.json` | the plugin | nobody (upgrades replace it) | plugin repo | every user, every project |
| `~/.agentic-board/roles.json` | nothing — you create it | you | **no** — per machine/user | every one of *your* projects |
| `.agentic-board/roles.json` | nothing — you create it | you | **yes** — roles are team knowledge | this project only |

The global file is for a role you use across several of your own repos and don't want to
redeclare in each one — e.g. a `powerbi` role that hooks DAX/PowerBI tooling, useful in every
PBI-related repo you touch. It lives at the same machine-wide state dir `Backup-Board.ps1` and
the welcome banner already use (`Get-AbiosStateDir -Root $HOME`), so it is never accidentally
committed into a project — it is not under any repo's `.git` at all.

> If your project's `.gitignore` excludes `.agentic-board/`, `roles.json` cannot be versioned:
> git **cannot re-include** a file whose parent directory is excluded, so a plain
> `!.agentic-board/roles.json` would be dead config that looks like it works. Exclude the
> directory's *contents* instead:
> ```gitignore
> .agentic-board/*
> !.agentic-board/roles.json
> ```
> This only applies to the **project-local** file — the global one is outside any repo, so it is
> never subject to a project's `.gitignore` in the first place.

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

Precedence, highest first: **local overrides global overrides factory**. Mechanically this is
the same union/replace merge applied twice — factory+global first, then that result+local —
never a bespoke three-way merge, so the rules below apply identically at both steps (read
"local" as "the more specific of the two files being merged" and "factory" as "the less
specific one"):

- The more specific file's roles are evaluated **before** the less specific one's; within each
  group, file order wins. A merged role takes the **more specific** position — declaring it
  there is what places it.
- `keywords` and `skills` **union** with the less specific role of the same name, so "we also
  call it `metabase`" does not require redeclaring the whole role.
- `agent`, `standards`, `knowledgeDomain` and `qualityProfile` **replace** wholesale. Setting
  `agent` clears any inherited `standards`, so the two never both apply.
- A project-local role always wins over a global one of the same name, and a global role always
  wins over a factory one — there is no way for the global tier to lock a project out of
  overriding it.

## When it goes wrong

A broken local file never leaves the expert worse off than the factory catalog:

| Condition | Behavior |
|---|---|
| No global or local file | Factory catalog. Normal, not a warning. |
| Invalid JSON, or an unknown `version`, in either overlay file | Warn; continue as if that file were absent. |
| A role missing `name`, `keywords` or `skills` | Warn; skip **that role only**. |
| Duplicate `name` within one file | Warn; the last declaration wins. |
| `agent` names something not installed | Warn; the role survives and falls back to `standards`, then to the generic paragraph. |
| `knowledgeDomain` names a missing domain | Warn; the role survives without the knowledge line. |
| The shipped preset is missing | Hard error — that is a broken install, not a misconfiguration. |

Every warning goes to the warning stream, never to stdout: `config` and `roles list` have parsed
output.

Run `/board expert roles why "<plan text>"` to see exactly which keyword decided a match, and
`/board expert roles` to see which roles hook zero skills.
