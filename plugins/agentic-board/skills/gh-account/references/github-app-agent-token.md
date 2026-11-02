# A GitHub App as the agent identity (#808)

A brake-armed run needs an identity that is **not** the owner: GitHub refuses its push to a
protected `main`, while it can still push branches and open PRs. A machine account's PAT does
that, but a PAT expires and has to be rotated by hand. A GitHub App does the same job with
tokens that last one hour and are minted on demand, so nothing long-lived sits in an env var.

Everything below uses placeholders. Nothing about your App goes into this repository.

## 1. Create and install the App

On GitHub: **Settings → Developer settings → GitHub Apps → New GitHub App**.

- Webhook: off.
- Repository permissions: **Contents**, **Issues**, **Pull requests** = Read and write;
  **Actions**, **Checks**, **Commit statuses** = Read. Leave **Administration**, **Workflows**
  and **Secrets** at No access: those are what the brake exists to keep away from the run.
- Install it on the repositories the agent may work in.
- Generate a private key (a `.pem`). Keep it in your secret manager, not on disk next to code.
- Note the **App ID** and the **installation ID** (`https://github.com/settings/installations/<id>`).

## 2. A local command that prints ONE installation token

Any executable works, as long as its stdout is the token and nothing else, and it exits non-zero
when it cannot mint. A PowerShell 7 sketch (`<APP_ID>`, `<INSTALLATION_ID>` and the key lookup
are yours to fill in):

```powershell
# app-token.ps1 - prints one GitHub App installation token on stdout, nothing else.
$ErrorActionPreference = 'Stop'
$appId = '<APP_ID>'; $installationId = '<INSTALLATION_ID>'
$pem   = <read the private key from your secret manager>        # never from a file in a repo
$b64u  = { param([byte[]]$b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
$now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$head  = & $b64u ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
$body  = & $b64u ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = $appId } | ConvertTo-Json -Compress)))
$rsa   = [Security.Cryptography.RSA]::Create(); $rsa.ImportFromPem($pem)
$sig   = & $b64u ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$head.$body"),
                  [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
$r = Invoke-RestMethod -Method Post -Uri "https://api.github.com/app/installations/$installationId/access_tokens" `
       -Headers @{ Authorization = "Bearer $head.$body.$sig"; Accept = 'application/vnd.github+json' }
[Console]::Out.Write($r.token)
```

The request body of `access_tokens` can narrow the token further (`repositories`,
`permissions`) if you want one run to reach less than the whole installation.

## 3. Point the account map at it

```powershell
./Set-AbiosAccounts.ps1 -AgentTokenCommand 'pwsh,-NoProfile,-File,~/path/to/app-token.ps1' `
                        -AgentGitName '<app-slug>[bot]' `
                        -AgentGitEmail '<bot-user-id>+<app-slug>[bot]@users.noreply.github.com'
./Set-AbiosAccounts.ps1 -Show
```

`<bot-user-id>` is public: `gh api users/<app-slug>[bot] --jq .id`. `-Show` lists the command
but never runs it. `-ClearAgentTokenCommand` goes back to `agentTokenVar`.

## What changes in a brake-armed run

- The launch script runs the command **before** the secret scrub (it may need your secret
  manager's own credential), keeps the output in a variable, and exposes it only as `GH_TOKEN`.
  It is never written to the launch script, the briefing, the transcript or the command line.
- No token, a non-zero exit, or an output that is not one token: the session does not start.
  It never falls back to the owner's token.
- Plain `git push` to `github.com` goes through `gh auth git-credential` (that `GH_TOKEN`)
  instead of the credential your machine stores for you, and commits are authored by the bot
  identity you set.
- Plugin scripts inside the run (`Get-GhTokenForContext`, `New-BoardPR.ps1`) mint their own
  fresh token through the same command. The scrub has removed every `*TOKEN*`/`*KEY*`/`*SECRET*`
  variable from the session's environment by then, so a command that needs its own credential
  must find it where the scrub does not reach (on Windows, the user scope of the variable).

## Stated limits

- An installation token lasts **one hour**. `GH_TOKEN` is set once at launch; a run that goes
  past the hour loses `gh` until it is relaunched. Plugin scripts are not affected (they mint
  per call).
- A GitHub App cannot use **Projects (v2) owned by a personal account**. On such a board, board
  moves inside an armed run fail; keep those with the owner, outside the run. Organization
  projects work when the App has the organization's Projects permission.
- As with any agent identity, this removes the default capability, not the possibility: a process
  running as you can still read your own stores.
