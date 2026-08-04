# /board field — presets and bulk-fill (full recipe)

Loaded on demand by /board (#573).

- **field** — two DISTINCT scripts, do not confuse them:
  - **apply a field preset** (`apply en|es`) → `scripts/Apply-FieldPreset.ps1 -ProjectNum <n> -Owner <o> -Lang en`
    (creates the preset's fields + canonical colors; `-Lang`/`-Preset` = `en|es`, NOT `-ApplyPreset`).
  - **bulk-fill ONE custom field across EVERY item by rule** → `scripts/Set-BoardField.ps1` (single-select
    by title-prefix map, or text by `{title}` template — idempotent, retries 502s).
  (references/field-presets.md + board-ops.md). Visibility-per-view and group-by are UI-only — say so.
  - **`apply <lang>` standardizes by DEFAULT.** A board born from GitHub's default template
    (`Todo / In Progress / Done`) is migrated onto the canonical preset with no flag: the legacy
    option is RENAMED in place (by option id → item assignments survive; `Todo`→`Backlog`,
    `P2 Medium`→`P2`, …), never duplicated. A rename hits every item at once, so ALWAYS preview with
    `--dry-run` first and let it confirm (`-Yes` only when already approved); answering `n` skips the
    standardizing and still applies the rest of the preset.
    This was opt-in behind `--migrate` until #300, and that default was the bug: matching options by
    name only, a plain apply added `Backlog` next to `Todo` and left the board in the one state a
    rename cannot repair. `-Migrate` is still accepted as a no-op. `--no-migrate` opts out and does
    NOT create the canonical option beside the legacy one — no path duplicates any more.
  - **`apply <lang> --merge-conflicts`** — for boards ALREADY carrying both (`Todo` *and* `Backlog`):
    moves the legacy option's items onto the canonical one, verifies, then deletes it. Destroys an
    option, so it stays opt-in. Preview with `--dry-run` first.
