<#
.SYNOPSIS
    /board setup - write or show your account map, ~/.agentic-board/accounts.json (#762).

.DESCRIPTION
    The map says which environment variable holds the token for each GitHub account you work
    with, which account is the default board owner, short aliases, and the variable of the
    optional machine identity that brake-armed autonomous runs use. It stores NAMES only - this
    script never reads, prints or writes a token value; -Show reports whether each variable is set.

    Without any map the plugin still works: every owner uses the ambient token (GH_TOKEN, then
    `gh auth token`). You need a map only for more than one account, or for the agent identity.

    Changes MERGE into the existing file; nothing else in it is touched. -DryRun prints the result
    without writing.

.EXAMPLE
    ./Set-AbiosAccounts.ps1 -Show
    ./Set-AbiosAccounts.ps1 -DefaultOwner my-login -Map 'my-login=GITHUB_TOKEN_PERSONAL'
    ./Set-AbiosAccounts.ps1 -Map 'my-org=GITHUB_TOKEN_WORK' -Alias 'work=my-org'
    ./Set-AbiosAccounts.ps1 -AgentTokenVar GITHUB_TOKEN_AGENT
    ./Set-AbiosAccounts.ps1 -Remove my-org
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [string]$DefaultOwner = '',
    # login=ENV_VAR pairs
    [string[]]$Map = @(),
    # accountId=ENV_VAR pairs (the numeric GitHub id survives a rename of the login)
    [string[]]$AccountId = @(),
    # alias=login pairs
    [string[]]$Alias = @(),
    [string]$AgentTokenVar = '',
    # logins (and aliases pointing at them) to drop from the map
    [string[]]$Remove = @(),
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-AbiosAccounts.ps1')

$loginRx = '^[A-Za-z0-9][A-Za-z0-9-]*$'
$varRx   = '^[A-Za-z_][A-Za-z0-9_]*$'

# 'a=b' -> @{ key; value }, validated. Pure.
function ConvertFrom-AbiosPair([string]$Pair, [string]$KeyRx, [string]$ValueRx, [string]$What) {
    $parts = "$Pair" -split '=', 2
    if ($parts.Count -ne 2 -or $parts[0].Trim() -notmatch $KeyRx -or $parts[1].Trim() -notmatch $ValueRx) {
        throw "Invalid $What '$Pair' - expected key=value (an env var NAME, never a token)."
    }
    return @{ key = $parts[0].Trim(); value = $parts[1].Trim() }
}

# Merge the requested changes into a config object and return the JSON-ready shape. Pure.
function Merge-AbiosAccounts {
    param([object]$Config, [string]$DefaultOwner, [string[]]$Map, [string[]]$AccountId,
          [string[]]$Alias, [string]$AgentTokenVar, [string[]]$Remove)
    $owners = @{} + $Config.owners; $ids = @{} + $Config.accountIds; $aliases = @{} + $Config.aliases
    $default = $Config.defaultOwner; $agent = $Config.agentTokenVar
    foreach ($p in $Map)       { $kv = ConvertFrom-AbiosPair $p $loginRx $varRx 'map entry';     $owners[$kv.key]  = $kv.value }
    foreach ($p in $AccountId) { $kv = ConvertFrom-AbiosPair $p '^\d+$' $varRx 'account id';      $ids[$kv.key]     = $kv.value }
    foreach ($p in $Alias)     { $kv = ConvertFrom-AbiosPair $p $loginRx $loginRx 'alias';        $aliases[$kv.key] = $kv.value }
    if ($DefaultOwner) {
        if ($DefaultOwner -notmatch $loginRx) { throw "Invalid -DefaultOwner '$DefaultOwner'." }
        $default = $DefaultOwner
    }
    if ($AgentTokenVar) {
        if ($AgentTokenVar -notmatch $varRx) { throw "Invalid -AgentTokenVar '$AgentTokenVar'." }
        $agent = $AgentTokenVar
    }
    foreach ($r in $Remove) {
        $owners.Remove($r)
        foreach ($a in @($aliases.Keys)) { if ($a -eq $r -or $aliases[$a] -eq $r) { $aliases.Remove($a) } }
        if ($default -eq $r) { $default = '' }
    }
    $sorted = { param($h) $o = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }; $o }
    $out = [ordered]@{}
    if ($default) { $out.defaultOwner = $default }
    $out.owners        = & $sorted $owners
    $out.accountIds    = & $sorted $ids
    $out.aliases       = & $sorted $aliases
    $out.agentTokenVar = $agent
    return $out
}

# One line per mapped variable: set or not, never the value.
function Format-AbiosAccountsReport([System.Collections.IDictionary]$Shape, [string]$Path) {
    $lines = @("Account map: $Path")
    $lines += "  default owner : $(if ($Shape.defaultOwner) { $Shape.defaultOwner } else { '(none - the login gh is signed in as)' })"
    if ($Shape.owners.Count -eq 0) { $lines += '  owners        : (none - every owner uses GH_TOKEN, then gh auth token)' }
    foreach ($k in $Shape.owners.Keys) {
        $v = $Shape.owners[$k]
        $lines += ('  {0,-14}: {1} [{2}]' -f $k, $v, $(if (Get-AbiosEnvValue -VarName $v) { 'set' } else { 'NOT SET' }))
    }
    foreach ($k in $Shape.accountIds.Keys) { $lines += ('  id {0,-11}: {1}' -f $k, $Shape.accountIds[$k]) }
    foreach ($k in $Shape.aliases.Keys)    { $lines += ('  alias {0,-8}: {1}' -f $k, $Shape.aliases[$k]) }
    $a = $Shape.agentTokenVar
    $lines += ('  agent identity: {0} [{1}]' -f $a, $(if (Get-AbiosEnvValue -VarName $a) { 'set' } else { 'not set - brake-armed runs will refuse to start' }))
    return $lines
}

if ($env:ABIOS_SETACCOUNTS_DOTSOURCE) { return }

$path = Get-AbiosAccountsPath
$cfg  = Get-AbiosAccountConfig -Path $path
if ($cfg.error) { throw "$($cfg.error). Fix or delete the file, then re-run." }
$shape = Merge-AbiosAccounts -Config $cfg -DefaultOwner $DefaultOwner -Map $Map -AccountId $AccountId `
                             -Alias $Alias -AgentTokenVar $AgentTokenVar -Remove $Remove
$changing = $DefaultOwner -or $Map -or $AccountId -or $Alias -or $AgentTokenVar -or $Remove

if ($changing -and -not $DryRun) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($shape | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
}
if ($Json) { $shape | ConvertTo-Json -Depth 4; exit 0 }
if ($changing) { Write-Host $(if ($DryRun) { '[DryRun] would write:' } else { 'Written.' }) -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' }) }
Format-AbiosAccountsReport -Shape $shape -Path $path | ForEach-Object { Write-Host $_ }
