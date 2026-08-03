---
name: gh-account
description: Use FIRST before any GitHub Projects/issues operation in the agentic-board suite. Resolves which account (default CSalcedoDataBI, override PAL-Devs) and reads its PAT from the Windows user registry, injecting GH_TOKEN per-invocation without touching `gh auth switch`. Triggers — any board/issue op, "cambia a CSalcedoDataBI", 403 on a PAL board, INSUFFICIENT_SCOPES/read:project.
user-invocable: false
---

# gh-account — Cross-Account GitHub Token Resolver

**Purpose:** Every operation in this suite that touches GitHub Projects or issues must begin here. This skill ensures the right PAT is loaded into `GH_TOKEN` for the duration of that single operation — without ever calling `gh auth switch`, which would corrupt the user's global `gh` CLI state.

---

## Default account: CSalcedoDataBI — always

The default identity for all operations in this suite is **CSalcedoDataBI**, even when you are working inside a PAL-Devs-owned repository. The account only changes when the user explicitly says "use PAL-Devs" or you encounter a 403 on a PAL-owned board (see below).

---

## FIRST: are you inside a brake-armed run? (#550)

Before anything else, check for `.agentic-board/brake-armed.json` in the current directory **or any
directory above it**. If it is there, this is an autonomous run that has been braked, and the
identity rule changes:

```powershell
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_AGENT', 'User')
if (-not $t) { throw 'Run frenado y GITHUB_TOKEN_AGENT no existe. NO uses el token del dueno.' }
$env:GH_TOKEN = $t
```

**Do NOT fall back to `GITHUB_TOKEN_PERSONAL` if the agent token is missing. Stop and say so.**

Why this matters more than it looks: `main` requires a pull request, but the rule **exempts the
repository admin role** — and the owner's PAT authenticates *as the owner*, so GitHub lets it push
to `main` directly. Weaker permissions on one of his tokens do not help; GitHub cannot tell "the
human typed this" from "an agent used the human's token", because they are the same principal.
Only a different identity gets a different answer. Measured, not assumed:

| Action as `powerbiconcristobal-ui` | Result |
|---|---|
| write to `main` | `Repository rule violations found — Changes must be made through a pull request (422)` |
| create an ordinary branch | 200 OK |

So the agent identity is refused exactly where it should be and can still do its work. Falling back
to the owner's PAT would hand the run the one capability the brake exists to remove, while every
message on screen still said "brake armed".

**Never** reach for `GITHUB_TOKEN_BUSINESS` here. On this repo it is read-only and looks harmless,
but the token is not repo-scoped: it carries **admin on 17 business repositories**, client work
included. It is the widest of the three identities, not the narrowest.

---

## Canonical inline command (preferred — path-independent)

This is what the agent should run at the start of any operation. It reads from the Windows USER registry, which is always current (unlike `$env:`, which reflects the value at login time and may be stale).

**PowerShell (default — CSalcedoDataBI):**
```powershell
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL', 'User')
$env:GH_TOKEN = $t
```

**PowerShell (PAL-Devs override):**
```powershell
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_BUSINESS', 'User')
$env:GH_TOKEN = $t
```

`$env:GH_TOKEN` is read by `gh` automatically. Set it, run the `gh` command, and optionally clear it — never use `gh auth switch`.

**Bash equivalent (when running from a POSIX context):**
```bash
tok=$(powershell.exe -NoProfile -Command "[System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_PERSONAL','User')" | tr -d '\r')
GH_TOKEN=$tok gh project list --owner CSalcedoDataBI --limit 5
```

For PAL-Devs, replace `GITHUB_TOKEN_PERSONAL` with `GITHUB_TOKEN_BUSINESS`.

---

## Convenience wrapper (with scope verification)

The helper script at `scripts/Get-GhAccount.ps1` (relative to the plugin root) wraps the inline command above and adds an automatic `project` scope check before returning the token object:

```powershell
$acct = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-GhAccount.ps1" -Account csalcedo
$env:GH_TOKEN = $acct.Token
# Now safe to run gh project / gh issue commands
```

For PAL-Devs:
```powershell
$acct = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-GhAccount.ps1" -Account pal-devs
$env:GH_TOKEN = $acct.Token
```

The script returns a `[pscustomobject]` with these fields:

| Field | Example |
|-------|---------|
| `Account` | `csalcedo` |
| `User` | `CSalcedoDataBI` |
| `Var` | `GITHUB_TOKEN_PERSONAL` |
| `Token` | `ghp_…` (handle with care; never log) |
| `Scopes` | `repo, project, read:org` |

If the Windows USER env var is missing, or if the token lacks `project` scope, the script writes an error and exits 1.

---

## Hard rules

- **Never run `gh auth switch`.** It changes the global `~/.config/gh/` state and will affect every subsequent `gh` call in the session, including operations unrelated to this suite.
- **Set `GH_TOKEN` only for the operation's scope.** After the `gh` call completes, you may clear it with `Remove-Item Env:GH_TOKEN` if other code in the same session must not inherit it.
- **Never print or log the raw token value.** The object `.Token` field exists only for assignment to `$env:GH_TOKEN`.

---

## Scope check

Before any board or Projects operation, confirm the token carries the `project` scope. The wrapper script does this automatically. If doing the inline command without the script, you can verify manually:

```powershell
$hdr = curl.exe -s -I -H "Authorization: token $env:GH_TOKEN" https://api.github.com/user
$hdr | Select-String 'x-oauth-scopes'
# Expected: x-oauth-scopes: repo, project, ...
```

If `project` is absent, tell the user: "Your PAT for [account] lacks the `project` scope. Go to GitHub → Settings → Developer settings → Personal access tokens and regenerate it with `project` checked."

---

## 403 on a PAL-owned board

If you receive a 403 while using the personal account (`CSalcedoDataBI`) on a board owned by `PAL-Devs` or `PAL-Devs/` repositories, this is an account mismatch. Instruct the caller to re-run the operation with `--account pal-devs`, which loads `GITHUB_TOKEN_BUSINESS` instead:

```powershell
$t = [System.Environment]::GetEnvironmentVariable('GITHUB_TOKEN_BUSINESS', 'User')
$env:GH_TOKEN = $t
# Retry the gh command
```

---

## Cross-account git push & PR (work step 5a)

`GH_TOKEN` covers `gh` API calls only — a `git push` authenticates through git's credential
machinery, which is a separate path. **Never solve this by embedding a token in the stored
remote URL** (it leaks into `git remote -v`, shell history, and every future clone of the
config). Use `scripts/New-BoardPR.ps1` instead:

```powershell
& "<plugin-root>/scripts/New-BoardPR.ps1" -Issue <n>          # account auto-resolved from repo owner
& "<plugin-root>/scripts/New-BoardPR.ps1" -Issue <n> -TokenVar GITHUB_TOKEN_BUSINESS   # force PAL-Devs
```

It resolves the account **from the repo owner** (CSalcedoDataBI → `GITHUB_TOKEN_PERSONAL`,
PAL-Devs → `GITHUB_TOKEN_BUSINESS`), verifies the login has push permission, pushes through a
one-shot credential helper (token only ever in an env var read inside git's shell), and opens
the PR with `Closes #<n>` — or pushes to the already-open PR on re-run. Session `GH_TOKEN` is
deliberately ignored there: the identity must match the repo owner, not whatever ran last.

---

## Verified status

Verified 2026-06-26: both Windows USER env vars (`GITHUB_TOKEN_PERSONAL` for CSalcedoDataBI and `GITHUB_TOKEN_BUSINESS` for PAL-Devs) exist on this machine and carry the `project` scope.
