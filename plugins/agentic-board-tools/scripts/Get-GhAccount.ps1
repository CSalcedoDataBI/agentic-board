<#  Get-GhAccount.ps1 - resolve the GitHub account + token for agentic-board.
    -Account takes an alias from your account map (~/.agentic-board/accounts.json, written by
    `/board setup`) or a login. Omitted, it is the map's defaultOwner, else the login `gh` is signed
    in as. The token comes from that account's env var in the map (Windows user scope, then the
    process), else the ambient GH_TOKEN / `gh auth token` (#762). Verifies the 'project' scope.
    Emits an object with .Token to set $env:GH_TOKEN.  #>
[CmdletBinding()]
param([string]$Account = '')

# The alias -> login and login -> token-variable maps live in one place, Resolve-GhTokenVar, which
# reads them from the user's account map (#550, #665, #762).
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT

$user = ''
if ($Account) {
    $user = Get-AccountForAlias -Alias $Account
    if (-not $user) {
        if ($Account -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { Write-Error "'$Account' is neither an alias in your account map nor a GitHub login."; exit 1 }
        $user = $Account
    }
} else {
    $user = Get-AbiosDefaultOwner
    if (-not $user) { Write-Error "No default account: run 'gh auth login', or /board setup to write ~/.agentic-board/accounts.json."; exit 1 }
}
$sel   = @{ User = $user; Var = (Get-OwnerTokenVar -Owner $user) }
$token = Get-GhTokenValue -VarName $sel.Var
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Error "No token for '$($sel.User)': '$($sel.Var)' is unset and gh has no stored login. Create a PAT with 'project'+'repo' scopes (or run 'gh auth login --scopes project') and map it with /board setup."
  exit 1
}
# Invoke-WebRequest, not curl.exe, so the scope check runs on every platform (#767).
$scopes = ''
try {
    $resp   = Invoke-WebRequest -Uri 'https://api.github.com/user' -Method Head -Headers @{ Authorization = "token $token" } -ErrorAction Stop
    $scopes = "$(@($resp.Headers['X-OAuth-Scopes'])[0])".Trim()
} catch { $scopes = '' }
if ($scopes -notmatch '\bproject\b') {
  Write-Error "Token for '$($sel.User)' lacks 'project' scope (has: $scopes). Regenerate the PAT with 'project', or run 'gh auth refresh --scopes project'."
  exit 1
}
[pscustomobject]@{ Account=$Account; User=$sel.User; Var=$sel.Var; Token=$token; Scopes=$scopes }
