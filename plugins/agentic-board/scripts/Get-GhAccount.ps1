<#  Get-GhAccount.ps1 — resolve GitHub account + token for agentic-board.
    Default account: CSalcedoDataBI. Override: -Account pal-devs.
    Reads the PAT from the Windows USER registry (not $env:, which can be stale).
    Verifies the 'project' scope. Emits an object with .Token to set $env:GH_TOKEN.  #>
[CmdletBinding()]
param([ValidateSet('csalcedo','pal-devs')][string]$Account = 'csalcedo')

# The CLI ALIAS -> user map is this script's own business. The user -> TOKEN VARIABLE map is not:
# it lived here, in Board-Merge, in New-BoardPR and in Publish-DocsWiki, four copies of one rule
# (#550). It comes from Resolve-GhTokenVar now.
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT

$aliasUser = @{ 'csalcedo' = 'CSalcedoDataBI'; 'pal-devs' = 'PAL-Devs' }
$user  = $aliasUser[$Account]
$sel   = @{ User = $user; Var = (Get-OwnerTokenVar -Owner $user) }
$token = [System.Environment]::GetEnvironmentVariable($sel.Var, 'User')
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Error "Token var '$($sel.Var)' not found in Windows USER env for '$($sel.User)'. Create a PAT with 'project'+'repo' scopes and set it."
  exit 1
}
$hdr    = curl.exe -s -I -H "Authorization: token $token" https://api.github.com/user
$scopes = (($hdr | Select-String -Pattern '^x-oauth-scopes:' ) -replace '(?i)^x-oauth-scopes:\s*','').Trim()
if ($scopes -notmatch '\bproject\b') {
  Write-Error "Token for '$($sel.User)' lacks 'project' scope (has: $scopes). Regenerate the PAT with 'project'."
  exit 1
}
[pscustomobject]@{ Account=$Account; User=$sel.User; Var=$sel.Var; Token=$token; Scopes=$scopes }
