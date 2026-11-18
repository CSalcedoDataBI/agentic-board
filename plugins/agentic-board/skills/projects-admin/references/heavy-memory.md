# Heavy-memory escalation (Basic Memory) - security-gated

The default handoff is the lightweight, git-committed `HANDOFF.md`. For the **heavy case
only** - persistent *semantic* memory across projects - `<tools>/scripts/Suggest-HeavyMemory.ps1`
proposes installing a reliable existing tool, **Basic Memory** (local Markdown + SQLite over
MCP), instead of reinventing memory infrastructure. It is an **opt-in escalation**, never the
default.

## Hard rule: AGPL-3.0

Basic Memory is **AGPL-3.0** (strong copyleft). We stay clean ONLY by the
suggest-and-install-from-upstream pattern:

- **Never vendor, fork, or copy Basic Memory's source into this repo, and never
  modify+redistribute it** - that would force `agentic-board` itself to become AGPL.
- The user installs it from its official source; our plugin only talks to it over MCP (a
  separate process = mere aggregation, no license inheritance). `agentic-board` stays MIT.

## What the script does

**Default run = proposal only** (installs nothing):

```powershell
pwsh -File <tools>/scripts/Suggest-HeavyMemory.ps1
```

1. **Provenance** - live PyPI lookup of `basic-memory`: verifies the canonical package name
   (anti-typosquatting; refuses on mismatch) and confirms the license really is AGPL.
2. Prints the **security checklist**, the **pinned** install command (exact version, never a
   floating range), the proposed `.mcp.json` entry (runs the pinned version via `uvx`), and
   the reversible uninstall.

**Guarded install** (every control enforced before touching the system):

```powershell
pwsh -File <tools>/scripts/Suggest-HeavyMemory.ps1 -Install -AcceptAgpl -Version x.y.z
```

The install **refuses** unless ALL hold:
- `-AcceptAgpl` is passed (the human gate) - no silent install.
- `-Version` is passed explicitly - **no blind `latest`**; pin the version the proposal showed.
- Provenance + AGPL were verified against PyPI *this run* (refuses if PyPI is unreachable).
- An isolated env manager (`uv` or `pipx`) is available - no global `pip`.

It installs the pinned version and writes a `basic-memory` MCP entry to `.mcp.json` whose
command **matches the manager used** (`uvx …` for uv, `pipx run --spec …` for pipx).

## Security checklist (the 5 controls)

1. **Provenance, no blind `latest`** - canonical name verified, exact version pinned.
2. **Isolation + least privilege** - `uv tool`/`pipx` isolated env; local-only (no network
   egress); review the MCP tools it exposes and scope its notes path via Basic Memory's own
   project config before relying on it.
3. **Human gate** - `-Install -AcceptAgpl`; no silent install.
4. **Update-review, not auto-update** - bumping is deliberate: review the changelog, re-pin,
   re-verify. Watch for maintainer/license changes between versions.
5. **Reversible uninstall** - `uv tool uninstall basic-memory` (or `pipx uninstall`) + remove
   the `.mcp.json` entry; your `.md` notes are preserved.

## When to reach for it

Only when the user explicitly wants persistent, queryable semantic memory that outlives a
single task. If the AGPL license or the SQLite index is unacceptable, the fallback is simply
the default `HANDOFF.md` - we do not build a heavy memory store ourselves.
