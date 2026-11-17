# First-run welcome banner (SessionStart hook)

`scripts/Welcome-SessionStartHook.ps1` greets the user with the elegant **AGENTIC BOARD**
banner **exactly once**, right after they install the plugin — so the real experience matches
the README demo GIF.

Unlike the handoff hook (which is opt-in), this one is **auto-registered** via
`agentic-board-hooks/hooks/hooks.json` and needs no setup beyond installing that companion plugin: it "just works" after
`/plugin install agentic-board-hooks@agentic-board`.

## Why a hook (and not the install screen)

The `/plugin install` screen is **Claude Code's own UI** — a plugin cannot restyle it, so the
install itself will always look plain. The banner therefore lives in the plugin's *own*
first-run output instead. A hook also can't paint the TUI directly, so the banner is surfaced
through the SessionStart **`additionalContext`** channel and rendered by the assistant as the
first thing it prints (the emitted context instructs it to print the banner verbatim).

## What it does

On session start it reads the hook's stdin JSON (`source`). It acts **only when
`source == "startup"`** (skips `resume`/`clear`/`compact`, so it never re-announces on a
resumed or compacted session) **and only when a global marker is absent**:

- **Once semantics:** a machine-wide marker at `<HOME>/.agentic-board/.welcomed`, resolved via
  `Get-AbiosStateDir -Root $HOME`. Once per install, **not** once per repo.
- The marker is written **before** the banner is emitted, so a mid-flight failure never causes
  a second welcome on the next startup.
- Read-only otherwise, **never blocks, never throws, always exits 0** — a failing SessionStart
  hook would disrupt startup.

## Registration (already wired)

`agentic-board-hooks/hooks/hooks.json` of the companion plugin `agentic-board-hooks`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/Welcome-SessionStartHook.ps1\""
          }
        ]
      }
    ]
  }
}
```

## See it again / reset

Delete the marker to replay the welcome on the next fresh session:

```powershell
Remove-Item "$HOME\.agentic-board\.welcomed" -ErrorAction SilentlyContinue
```

## Tests

`tests/Welcome-SessionStartHook.Tests.ps1` covers the pure helpers via the dot-source guard
(`$env:ABIOS_WELCOME_HOOK_DOTSOURCE`): the `startup`-and-no-marker gate, the banner content,
and the verbatim-print instruction.
