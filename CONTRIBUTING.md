# Contributing to agentic-board

Thanks for helping improve **agentic-board** — the Claude Code plugin that runs coding agents
off your real GitHub Projects board. This guide covers the one rule that is non-obvious (private
→ public), how to set up, and how a change gets from an idea to a merged PR.

## The one rule: private cause, public contribution

This tool improves itself. Most fixes are discovered while using it inside **private** projects.
The hard rule is: **the cause may be private, but the contribution must be public-only** — no repo
names, client names, data, GUIDs, tokens, or file paths from a private project may land here.

Two layers protect the repo — please keep both honest:

1. **Discipline.** The `abios-feedback` skill captures each improvement abstracted to the public
   tool. When you file an issue or open a PR, describe the *general* problem, not the private case.
2. **A guard you can't forget.** After cloning, run once:
   ```
   pwsh -File scripts/install-guard.ps1
   ```
   This wires `pre-commit` + `pre-push` hooks that **block** any commit/push whose added lines
   contain a known secret pattern or a term from your local `.abios/private-denylist.txt`
   (gitignored — seed it with your own private fingerprints). Only override (`--no-verify`) for a
   confirmed false positive.

## Setup

1. Install and authenticate the [`gh` CLI](https://cli.github.com/).
2. Provide a GitHub **Personal Access Token** (classic) with the `project` and `repo` scopes. The
   plugin reads it from a per-account environment variable — never from the repo. On Windows the
   default is the user env var `GITHUB_TOKEN_PERSONAL`; on macOS/Linux export `GH_TOKEN` yourself.
3. Install [Pester 5](https://pester.dev/) to run the test suite (`Install-Module Pester -MinimumVersion 5.5.0`).

## Making a change

The tool can drive its own contribution flow — the fastest path is to let it:

```
/board work                      # pick a pending issue and start it (branch + worktree)
```

That moves the issue to **In Progress**, creates `issue-<num>-<slug>`, and briefs you with the
full context. Or do it by hand:

1. **Branch per change.** `git checkout -b issue-<num>-<slug>` off a fresh `main`.
2. **One issue, one focused PR.** Small PRs review better; the review gate warns past 600 lines /
   20 files and suggests splitting with sub-issues.
3. **Open a PR that closes the issue.** The [PR template](.github/PULL_REQUEST_TEMPLATE.md) has a
   `Closes #` slot — fill it so the merge closes the issue and updates the board automatically.
   Never commit board-tracked work directly to `main`.
4. **Pass the review gate.** CI (the Pester suite) must be green, a code review requested, and no
   unresolved threads. If no reviewer is available, self-review the full `gh pr diff` and say so.

## Tests

The suite lives in `plugins/agentic-board/tests/`. Run it locally before
opening a PR — CI runs the same suite on every PR and **blocks the merge on any failure**:

```powershell
Invoke-Pester -Path plugins/agentic-board/tests
```

New behavior needs a test. Side-effecting scripts expose a dot-source guard (e.g.
`$env:ABIOS_BOARDFILL_DOTSOURCE`) so their pure helpers can be unit-tested without hitting `gh`.

## Conventions

- **Commits & board content in English**, [Conventional Commits](https://www.conventionalcommits.org/)
  style (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
- **PowerShell** for scripts; match the surrounding style.
- **Don't rename internal state keys casually.** The state dir and `ABIOS_*` env vars are on-disk
  identifiers on users' machines — renaming them orphans live sessions and backups. The current
  state dir is `.agentic-board/` (with `~/.agentic-board/backups`); the pre-rebrand `.agentic-bi-ops/`
  is migrated transparently. Both are resolved through the single `Get-AbiosStateDir` helper —
  never hard-code either literal elsewhere, and any future rename must go through that helper with
  the same one-time migration + fallback.
- Keep the `gh` remote a bare URL; auth flows through the token env var, never a PAT baked into the
  URL.

## Command surface

The tool exposes **two kinds of entry point**, and they must never be confused — that confusion is
what let a menu tell users to type `/abios-feedback`, a command that does not exist.

- **Typed command** — a `plugins/agentic-board/commands/<noun>.md` file. It appears in the `/`
  palette as `/agentic-board:<noun>` (plugin commands are always namespaced; there is no bare
  `/<noun>` fallback). The user types it. Today: `board`, `skills`, `knowledge`, `scan`.
- **Internal skill** — a `plugins/agentic-board/skills/<name>/SKILL.md` with
  `user-invocable: false`. It is **hidden from the palette and never typed**; the model invokes it
  from its `description` when the work matches (account resolution, board admin, `abios-feedback`,
  `tmdl-review`, …). A user "runs" it by saying what they want in natural language, not `/<name>`.

Rules for any new (or renamed) piece:

1. **Pick the right kind.** A door the *user* opens → a command. A capability the *model*
   orchestrates in the background → an internal skill (`user-invocable: false`). Don't add a
   command for something only the model should trigger, and don't hide a real user entry point in a
   `user-invocable: false` skill.
2. **Noun-verb.** The command file is the **noun**; its **verbs are arguments** (`/board work`,
   `/skills bootstrap bi`). The command dispatches on `$ARGUMENTS`. Add `argument-hint` when it
   takes positional args.
3. **`description` is a contract, not a tagline.** It is both the palette text *and* the generated
   README catalog (see [Docs](#docs)). Keep it factual and **list the verbs** so it never
   understates what the command does.
4. **No args → a menu**, and that menu lists **only real, current verbs**.
5. **Menus never lie.** Anything a menu presents as a typeable `/x` **must be a real command file**.
   An internal skill is referred to by what the user would say, never dressed up as `/x`. (This is
   the invariant `CommandSurface.Tests.ps1` enforces.)
6. **Keep the surface in sync.** When you add or rename a verb, update in the same PR: the command's
   own menu, its routing/dispatch section, its `description`, the `/board` "otros módulos"
   cross-reference, and regenerate the README (`Update-Docs.ps1`). The docs-freshness gate and
   `CommandSurface.Tests.ps1` fail the PR otherwise.

## Docs

Two parts of `README.md` are **generated, not hand-written**, so they can't drift: the command
catalog (from each `commands/*.md` frontmatter `description`) and the version string (from
plugin.json). They live between `<!-- BEGIN:commands -->`/`<!-- END:commands -->` and
`<!-- BEGIN:version -->`/`<!-- END:version -->` markers — edit the *source*, then regenerate:

```powershell
plugins/agentic-board/scripts/Update-Docs.ps1            # rewrite the marked regions in place
plugins/agentic-board/scripts/Update-Docs.ps1 -Check     # exit 1 if the README is stale (CI gate)
```

Everything outside the markers stays hand-written. `-Check` is exit-code clean (0 fresh / 1 stale)
so a docs-freshness gate can block a PR that edited a command's description without regenerating.

## Product agenda: user-facing first, self-governance second (#576)

The cold engineering review that produced epic #561 measured the last week of releases at
**8:1 self-directed to user-facing** — thirty mentions of *brake*, twenty-eight of *expert*,
twenty-six of *defect*, against ten of *skills* and zero of *board fill*. Sixty-six releases in
thirty-nine days, and the three most recent added only mechanisms for governing the tool's own
autonomous runs.

That pattern has a root cause worth naming: **a tool that cannot measure its own runs keeps
inventing textual mechanisms to assert that its runs went well** (the changelog itself calls
this "the founding defect — reporting intent as fact"). Instrumentation is the cheaper cure,
and #568 finally added the time dimension. With that in place, the standing policy is:

1. **A release should carry at least one change a board USER can feel** — a faster wait, a verb
   that does more, a clearer surface. Pure self-governance batches are for regressions and
   security only.
2. **Before building a new self-control mechanism, ask what MEASUREMENT would make it
   unnecessary.** The run-ledger existed to survive compactions largely caused by a 72 KB
   instruction payload (#573 removed the weight); the evidence-×3 ceremony existed because
   nothing verified runs (`Expert-RunVerify.ps1` now does, against ONE artifact).
3. **Field evidence outranks introspection.** `/board telemetry` reads real sessions — with
   durations since #568. When choosing the next piece of work, an episode from the field ledger
   beats a hypothesis about the tool's own governance.

This is a policy, not a gate: nothing enforces it mechanically, and that is deliberate — it is
a judgement about where the next hour goes, made by whoever holds the roadmap.

## Releasing

`plugins/agentic-board/.claude-plugin/plugin.json` is the **single source of truth** for the
version; the plugin entry in `.claude-plugin/marketplace.json` mirrors its `name` + `description`
(nothing restates the version). `scripts/New-Release.ps1` prepares a release and **stops before
committing** so you review the diff first:

```powershell
# from the repo root
plugins/agentic-board/scripts/New-Release.ps1 -Check          # validate manifests + semver (no writes)
plugins/agentic-board/scripts/New-Release.ps1 -Bump minor -DryRun   # preview current -> next
plugins/agentic-board/scripts/New-Release.ps1 -Bump patch     # bump plugin.json + fold the CHANGELOG
```

It bumps the version (targeted, so the rest of `plugin.json` is byte-preserved), folds the board's
Done issues into `CHANGELOG.md` under the new version (via `Board-Changelog.ps1`), and validates
that `marketplace.json` hasn't drifted from `plugin.json` (`-SyncManifest` rewrites it from the
source of truth). Then review `git diff` and commit `chore(release): X.Y.Z` yourself. `-Check` is
exit-code clean (0 ok / 1 drift) so a CI gate can call it.

### What happens after the version-bump lands on `main`

Two channels, so users never install whatever `main` HEAD happens to be:

- **`main`** is the development channel — every merged PR lands here.
- **`release`** is the branch installs actually fetch. `marketplace.json`'s plugin `source` is a
  `git-subdir` pinned at `ref: release` (#323), so a fresh install or `plugin update` gets the
  `release` commit, not `main` HEAD.

When a `chore(release): X.Y.Z` commit changes `plugin.json`'s version on `main`, the **Release**
workflow (`.github/workflows/release.yml`, #322) fires automatically and:

1. creates the git tag `vX.Y.Z` + a GitHub Release, notes taken from that version's `CHANGELOG.md`
   block (`scripts/Get-ReleaseNotes.ps1`), on the exact commit that set the version, and
2. fast-forwards the `release` branch to that commit — the one push that moves pinned installs.

So tagging and the release channel are **no longer manual**: land the version bump on `main` and CI
does the rest. `plugin.json`'s `version` is still what drives `plugin update` detection for users, so
it must change on every release (the bump commit is exactly that).

## Good first issues

New here? Look for the [`good first issue`](https://github.com/CSalcedoDataBI/agentic-board/labels/good%20first%20issue)
label. Questions or a design idea? Open an issue with the **feature** or **task** template first —
it's cheaper to align before code.

## License

By contributing you agree your work is licensed under the repo's [MIT License](./LICENSE).
