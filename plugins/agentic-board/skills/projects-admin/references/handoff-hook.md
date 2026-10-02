# SessionStart auto-load hook (opt-in)

`scripts/Handoff-SessionStartHook.ps1` makes a saved handoff **surface itself** when you
**resume** a prior session, so you do not have to remember `Board-Handoff.ps1 -Resume`. It is
**opt-in** - a hook that runs on session start should be a deliberate choice.

## What it does

On session start it reads the hook's stdin JSON (`source`, `cwd`). It acts **only when
`source` is `"resume"`** (a fresh startup is instead covered by the self-cleaning MEMORY.md
pointer from `-Save`, see #141, which avoids re-announcing a stale `HANDOFF.md` on every new
session). On resume it looks for a local `HANDOFF.md` at the current repo root, and - if
present - emits a one-line `additionalContext` so the assistant immediately knows there is a
handoff to resume:

```
A saved /board handoff exists for issue #141, saved 2026-07-07T19:13:47Z (HANDOFF.md at the
repo root). Next step: <...>. Run 'Board-Handoff.ps1 -Resume' to rehydrate the full context.
```

It is **read-only and offline** (only reads the local `HANDOFF.md` mirror - never the network),
acts only on `resume` (and on `compact`, which the plugin already registers), never blocks, and never throws (a failing SessionStart hook
would disrupt startup, so it always exits 0). The durable board comment is fetched by
`-Resume`, not by the hook.

## Enable it (settings.json SessionStart hook)

The plugin already registers this script for `compact`. Showing the handoff on `resume` is opt-in:
add the entry below to `.claude/settings.json` (project) or `~/.claude/settings.json` (global).
`${CLAUDE_PLUGIN_ROOT}` is only set for hooks a plugin registers itself, so here use the absolute
path of the installed plugin (`installPath` in `claude plugin list --json`). The matcher is
`resume`, not `*`: with `*` the script would run twice on every compaction.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "resume",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"<plugin path>/scripts/Handoff-SessionStartHook.ps1\""
          }
        ]
      }
    ]
  }
}
```

## Relation to the MEMORY.md pointer

`Board-Handoff.ps1 -Save` also drops a machine-local auto-memory pointer (`active-handoff.md` +
a `MEMORY.md` line) that surfaces on the next session. The two are complementary: the
**MEMORY.md pointer** works wherever Claude Code auto-memory is enabled; this **hook** works
from the local `HANDOFF.md` and can quote the concrete next step. Enable either or both.

## Disable it

Remove the SessionStart hook entry. `HANDOFF.md` is local and gitignored; deleting it is safe.
