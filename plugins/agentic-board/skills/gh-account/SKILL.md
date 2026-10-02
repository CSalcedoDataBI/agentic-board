---
name: gh-account
description: "Use before any agentic-board GitHub Projects/issues operation: resolves the account for the repo owner and injects its token as GH_TOKEN per call, without gh auth switch. Not for general gh/git use outside agentic-board commands. Triggers — a /board, /scan or /expert GitHub call, a 403 on a board, INSUFFICIENT_SCOPES/read:project."
user-invocable: false
---

# gh-account — which GitHub identity, and its token

**Purpose:** every operation in this suite that touches GitHub Projects or issues starts here. It
loads the right token into `GH_TOKEN` for that operation, without `gh auth switch` (which would
change the user's global `gh` state).

## The account map (#762)

Which env var holds which account's token is the **user's own map**,
`~/.agentic-board/accounts.json`, written by `/board setup` (`scripts/Set-AbiosAccounts.ps1`).
It stores env var NAMES, never tokens. With no map, every owner uses the ambient token: `GH_TOKEN`,
then `gh auth token`. So a single-account user needs nothing beyond `gh auth login`.

The default owner is the map's `defaultOwner`, else the login `gh` is signed in as.

## FIRST: are you inside a brake-armed run? (#550)

Look for `.agentic-board/brake-armed.json` in the current directory **or any directory above it**.
If it is there, this is a braked autonomous run, and the only valid identity is the agent's
(the map's `agentTokenVar`, default `GITHUB_TOKEN_AGENT`). **If that variable is unset, STOP and
say so — never fall back to the owner's token.** The owner's PAT authenticates *as the owner*,
and a `main` rule that exempts admins lets it push straight to `main`; a separate machine identity
without admin is refused there (measured: HTTP 422 "Changes must be made through a pull request")
while it can still create ordinary branches. Falling back would hand the run the one capability
the brake exists to remove.

## Get the token (preferred)

```powershell
$acct = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-GhAccount.ps1"                 # default owner
$acct = & "${CLAUDE_PLUGIN_ROOT}/scripts/Get-GhAccount.ps1" -Account work   # an alias or a login
$env:GH_TOKEN = $acct.Token
```

It resolves the login, reads its variable from the map (Windows user scope, then the process),
falls back to `GH_TOKEN` / `gh auth token`, and checks the `project` scope. It returns
`Account, User, Var, Token, Scopes`; never print `.Token`. It exits 1 with the fix when the token
is missing or lacks `project`.

Scripts that talk to GitHub resolve the identity themselves through `Get-GhTokenForContext`
(`scripts/Resolve-GhTokenVar.ps1`), which applies the same map and the brake rule.

## Hard rules

- **Never run `gh auth switch`.**
- **Never print or log a token.** Ask users for env var NAMES, never for token values.
- Set `GH_TOKEN` for the operation; clear it with `Remove-Item Env:GH_TOKEN` when later code must
  not inherit it.

## Missing `project` scope / 403 on a board

- `INSUFFICIENT_SCOPES` / `read:project`: the token lacks `project`. A PAT: regenerate it with
  `project` + `repo`. The `gh` login: `gh auth refresh --scopes project`.
- 403 on a board owned by another account: an account mismatch. Re-run the command with `--account <alias>` (or `Get-GhAccount.ps1 -Account <alias>`),
  or map that owner with `/board setup`.

## Cross-account git push & PR

`GH_TOKEN` covers `gh` only; `git push` uses git's credential machinery. **Never embed a token in
the remote URL** (it leaks into `git remote -v`, shell history and copies of the config). Use
`scripts/New-BoardPR.ps1 -Issue <n>`: it resolves the account from the repo owner, checks push
permission, pushes through a one-shot credential helper and opens the PR with `Closes #<n>`.
`-TokenVar <VAR>` forces an identity outside a braked run.

## Renamed accounts and unmapped owners (#665)

The map is keyed on the owner **login**, and logins get renamed. Keep old logins as extra `owners`
entries, and add the numeric account ID (`gh api users/<login> --jq .id`, public) under
`accountIds`: an unknown login whose ID is known resolves to that account and says it was renamed.
An owner the map does not know uses the default owner's variable (else the ambient token), with a
warning that names it — the warning is about the **map**, not about permissions. It is never
resolved to another mapped, possibly wider, account.
