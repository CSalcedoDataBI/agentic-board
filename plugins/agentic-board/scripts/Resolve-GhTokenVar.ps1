<#
.SYNOPSIS
    Decide WHICH GitHub identity applies here (#550, part of #541).

.DESCRIPTION
    There are three tokens in the Windows USER environment and they are not interchangeable:

      GITHUB_TOKEN_PERSONAL  CSalcedoDataBI          admin on the personal repos
      GITHUB_TOKEN_BUSINESS  PesanteAnalytics        20 repos, ADMIN on 17 - never for an agent
                             (was PAL-Devs, was Support1-PAL: one account, renamed twice)
      GITHUB_TOKEN_AGENT     powerbiconcristobal-ui  machine account: write, no admin, one repo

    WHY THIS FILE EXISTS. The autonomy brake could never be complete as a text classifier: it
    decides what a shell command WILL DO by looking at its characters, and the space of harmless
    commands is unbounded. Eleven of the nineteen defects found on 2026-07-31 were that same defect
    in different clothes.

    The capability side is different in kind. `main` requires a pull request, but the ruleset
    bypasses the repository ADMIN ROLE - and a PAT authenticates AS ITS OWNER, so any token of his
    walks straight through. Weaker permissions do not help: GitHub cannot tell "the human typed
    this" from "an agent used the human's token", because they are the same principal. Only a
    DIFFERENT identity gets a different answer. Measured, not argued:

        PATCH .../git/refs/heads/main  as powerbiconcristobal-ui
        -> Repository rule violations found. Changes must be made through a pull request. (422)
        POST  .../git/refs (ordinary branch)  as the same identity
        -> 200 OK

    So inside a brake-armed worktree the answer is the agent identity, and everywhere else it is
    the account default. Pure (no filesystem writes, no network) behind a dot-source guard.

    STATED LIMIT, because this repo keeps paying for overclaiming: this decides which variable the
    TOOLING reads. A run that ignores it and reads GITHUB_TOKEN_PERSONAL from the registry itself is
    not stopped - the token is ambient in the user environment and cannot be taken away from a
    process running as that user. What this removes is the default capability, not the possibility.
    The controls for the deliberate case are #517 and the review gate.

.EXAMPLE
    . .\Resolve-GhTokenVar.ps1 ; Resolve-GhTokenVar -StartDir (Get-Location).Path
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

$script:AgentTokenVar = 'GITHUB_TOKEN_AGENT'

# Owner -> its variable. Same mapping the merge path already uses; kept in one place so the two
# cannot drift apart.
#
# A login is not an identity: GitHub accounts get renamed, and this key is the only thing that
# tied a repository to its token (#665). The business account has been Support1-PAL, then
# PAL-Devs, and since 2026-08-14 PesanteAnalytics - the SAME account and the SAME PAT throughout,
# because a PAT is bound to the account ID. Old logins stay listed as aliases: a clone made
# before a rename still has the old owner in its remote, and once the old name is released
# GitHub no longer redirects it (measured 2026-09-18: users/PAL-Devs is 404).
$script:OwnerTokenVar = @{
    'CSalcedoDataBI'  = 'GITHUB_TOKEN_PERSONAL'
    'PesanteAnalytics' = 'GITHUB_TOKEN_BUSINESS'
    'PAL-Devs'        = 'GITHUB_TOKEN_BUSINESS'
    'Support1-PAL'    = 'GITHUB_TOKEN_BUSINESS'
}

# The rename-proof key: the numeric account ID. It survives every rename, so a login this file has
# never heard of (the NEXT rename) can still be matched to its token by asking GitHub who owns it.
# IDs are public (`gh api users/<login> --jq .id`). Only ever consulted for a login that is NOT in
# the map above, and it can only choose between the two owner variables - never the agent's.
$script:AccountIdTokenVar = @{
    '73630372'  = 'GITHUB_TOKEN_PERSONAL'   # CSalcedoDataBI
    '248682413' = 'GITHUB_TOKEN_BUSINESS'   # PesanteAnalytics (ex PAL-Devs, ex Support1-PAL)
}

# CLI alias (Get-GhAccount -Account) -> the account's CURRENT login. Lived as a second copy in
# Get-GhAccount.ps1, documented as "kept in one place so the two cannot drift apart" (#665).
$script:AccountAlias = @{
    'csalcedo' = 'CSalcedoDataBI'
    'pesante'  = 'PesanteAnalytics'
    'pal-devs' = 'PesanteAnalytics'   # historical alias, kept so existing invocations keep working
}

<#
    Which token variable applies for work starting at $StartDir?

    $IsArmed is passed IN rather than probed here so the decision stays pure and testable; callers
    use Brake-Guard's Read-BrakeMarker (or the fast probe) to establish it.

    $AgentTokenPresent likewise: whether the machine account's token actually exists in the
    environment. It is a parameter because the ANSWER WHEN IT IS MISSING is the interesting part -
    see below.

    Returns a hashtable: @{ var; reason; fail; mapped }.

      fail = $true means: an armed run has no agent identity available. The caller must STOP, not
      quietly continue as the owner. A silent fallback would hand the run exactly the identity the
      brake exists to keep away from it, while every message on screen still said "brake armed" -
      the precise shape of the defect this repo has now found in the brake (#440), the review gate
      (#510) and the evidence blocks (#479).

      mapped = $false means: NOT armed, and the owner is not a login (or account ID) this file
      knows. `var` is still the personal variable - the long-standing default - but `reason` says,
      naming the owner, that this is a fallback and that the problem is the MAP, not the user's
      permissions (#665). An armed run never reaches that question: the agent identity is not
      per-account, so the owner is not even looked up.

    -IdLookup: optional scriptblock, login -> account ID string ('' when unknown). Left out, the
    decision stays pure (no network); Get-GhTokenForContext supplies the real lookup.
#>
function Resolve-GhTokenVar {
    param(
        [bool]$IsArmed = $false,
        [bool]$AgentTokenPresent = $false,
        [string]$Owner = 'CSalcedoDataBI',
        [scriptblock]$IdLookup
    )
    if (-not $IsArmed) {
        $res = Resolve-OwnerTokenVar -Owner $Owner -IdLookup $IdLookup
        $why = if ($res.mapped) { "no es un run frenado - identidad normal ($($res.var))" }
               else             { $res.reason }
        return @{ var = $res.var; fail = $false; mapped = $res.mapped; reason = $why }
    }
    if (-not $AgentTokenPresent) {
        return @{ var = ''; fail = $true; mapped = $true
                  reason = "run FRENADO y $script:AgentTokenVar no esta en el entorno. No se " +
                           "continua con el token del dueno: es admin y la regla de main lo " +
                           "exceptua, asi que seguir seria devolverle justo lo que el freno le quita." }
    }
    return @{ var = $script:AgentTokenVar; fail = $false; mapped = $true
              reason = "run frenado - identidad de agente ($script:AgentTokenVar): sin admin, " +
                       "GitHub le rechaza el push a main" }
}

<#
    May a caller's EXPLICIT -TokenVar be honoured here? (#550, review round 2)

    The first cut let an explicit override skip the armed check entirely, with the comment
    "explicit override wins". That was a bypass written as a feature: a braked run only had to add
    `-TokenVar GITHUB_TOKEN_PERSONAL` to its own invocation to get the owner's admin identity back,
    with no error and no warning - while the CHANGELOG claimed a missing agent token could never
    fall back to the owner's PAT. It could, in one flag.

    Outside an armed run an override is ordinary and always allowed: that is how cross-account work
    happens. Inside one, the ONLY variable a caller may name is the agent's - naming any other is
    refused, because the whole point is that this run does not get to choose its identity.
#>
function Test-ExplicitVarAllowed {
    param(
        [bool]$IsArmed = $false,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExplicitVar
    )
    if (-not $ExplicitVar) { return $true }          # nothing to allow
    if (-not $IsArmed)     { return $true }          # ordinary session: the caller decides
    return ($ExplicitVar -eq $script:AgentTokenVar)  # armed: only the agent identity
}

# The owner -> variable map, as a function so callers stop copying the literal. Four scripts each
# carried their own copy before #550; that is how one rule becomes four that disagree.
function Get-KnownOwners {
    return @($script:OwnerTokenVar.Keys)
}

# Who owns this login, as GitHub's stable numeric account ID ('' when it cannot be established).
# The ID is what a rename cannot change. Public data: no token is chosen or read for it, the
# ambient gh auth is used as-is. Kept as its own function so the tests drive Invoke-Gh's real
# parsing and mock only the process seam (Invoke-GhRaw).
function Get-OwnerAccountId {
    param([string]$Owner)
    # A login is [A-Za-z0-9-]. Anything else would be spliced into an API path, and it can only
    # have come from a malformed remote.
    if ($Owner -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { return '' }
    if (-not (Get-Command Invoke-Gh -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
    }
    try {
        $out = Invoke-Gh -GhArgs @('api', "users/$Owner", '--jq', '.id') `
                         -What "resolver el ID de la cuenta '$Owner'"
    } catch { return '' }
    $id = ((@($out) | ForEach-Object { "$_" }) -join '').Trim()
    if ($id -match '^\d+$') { return $id }
    return ''
}

<#
    Owner login -> token variable, and HOW SURE WE ARE (#665).

    Order: (1) the login is in the map, aliases included; (2) if an -IdLookup is supplied, the
    login is unknown but its numeric account ID is one we know - a renamed account; (3) neither:
    unmapped.

    Unmapped still returns the personal variable, because that has always been the default for a
    repo of some third party. What changed is that it SAYS so: mapped=$false and a reason that
    names the owner and lists the logins the map knows. It must never read as a permissions
    problem - the user is an admin, the token is fine, what is stale is a hardcoded login.

    This never returns the BUSINESS variable for an owner it could not match. The only way to the
    wider identity is a login/ID that is positively the business account.

    Returns @{ var; mapped; how = 'login'|'account-id'|'unmapped'; reason }.
#>
function Resolve-OwnerTokenVar {
    param(
        [string]$Owner = 'CSalcedoDataBI',
        [scriptblock]$IdLookup
    )
    if ($Owner -and $script:OwnerTokenVar.ContainsKey($Owner)) {
        $v = $script:OwnerTokenVar[$Owner]
        return @{ var = $v; mapped = $true; how = 'login'
                  reason = "owner '$Owner' esta en el mapa ($v)" }
    }
    $known = (@($script:OwnerTokenVar.Keys) | Sort-Object) -join ', '
    $note  = ''
    if ($Owner -and $IdLookup) {
        $id = ''
        try { $id = "$(& $IdLookup $Owner)".Trim() } catch { $id = '' }
        if ($id -and $script:AccountIdTokenVar.ContainsKey($id)) {
            $v = $script:AccountIdTokenVar[$id]
            return @{ var = $v; mapped = $true; how = 'account-id'
                      reason = "owner '$Owner' no esta en el mapa por login, pero su ID de cuenta " +
                               "($id) es la de una cuenta conocida ($v): se renombro. Agrega el " +
                               "login nuevo a `$OwnerTokenVar en Resolve-GhTokenVar.ps1." }
        }
        $note = if ($id) { " Su ID de cuenta ($id) tampoco es de ninguna cuenta conocida." }
                else     { ' No se pudo consultar su ID de cuenta en GitHub.' }
    }
    return @{ var = 'GITHUB_TOKEN_PERSONAL'; mapped = $false; how = 'unmapped'
              reason = "owner '$Owner' no esta mapeado a ninguna cuenta conocida ($known).$note " +
                       "Se usa GITHUB_TOKEN_PERSONAL por defecto. Es un problema del MAPA " +
                       "owner->token, no de permisos: si esa cuenta se renombro, agrega su login " +
                       "en Resolve-GhTokenVar.ps1 o pasa -TokenVar." }
}

function Get-OwnerTokenVar {
    param(
        [string]$Owner = 'CSalcedoDataBI',
        # Default: ask GitHub for the account ID of a login the map does not know (a renamed
        # account). Tests pass a fake.
        [scriptblock]$IdLookup = { param($o) Get-OwnerAccountId -Owner $o }
    )
    $r = Resolve-OwnerTokenVar -Owner $Owner -IdLookup $IdLookup
    if (-not $r.mapped) { Write-Warning $r.reason }
    return $r.var
}

# The CLI alias (csalcedo / pesante / pal-devs) -> current login. '' when the alias is unknown.
function Get-AccountForAlias {
    param([Parameter(Mandatory)][string]$Alias)
    $v = $script:AccountAlias[$Alias]
    if ($v) { return $v }
    return ''
}

function Get-KnownAccountAliases {
    return @($script:AccountAlias.Keys)
}

<#
    Is this directory inside a brake-armed worktree?

    Self-contained on purpose: no dot-source of Brake-Guard.ps1. A resolver that has to load
    another file to answer "which token" would fail in exactly the places it matters most, and a
    dot-source here would also run that file's param() block in the caller's scope - the trap that
    silently disabled the merge gate's CI check (#536).
#>
function Test-InBrakedRun {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StartDir)
    $dir = $StartDir
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $dir '.agentic-board') 'brake-armed.json')) { return $true }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $false
}

<#
    The one call every script should make: decide the identity AND load it.

    Returns the token value, or THROWS when an armed run has no agent identity. Throwing is the
    point: the alternative is continuing as the owner, whose PAT the `main` ruleset exempts.
#>
function Get-GhTokenForContext {
    param(
        [string]$StartDir = (Get-Location).Path,
        [string]$Owner = 'CSalcedoDataBI',
        # A caller's explicit -TokenVar. Passed IN rather than handled by the caller, so the armed
        # check cannot be skipped by taking a different branch - which is exactly how the first cut
        # of this leaked (review round 2).
        [string]$ExplicitVar = '',
        # Seam for tests; the default asks GitHub, and only for an owner the map does not know.
        [scriptblock]$IdLookup = { param($o) Get-OwnerAccountId -Owner $o }
    )
    $armed = Test-InBrakedRun -StartDir $StartDir
    if (-not (Test-ExplicitVarAllowed -IsArmed $armed -ExplicitVar $ExplicitVar)) {
        throw ("Run FRENADO: -TokenVar '$ExplicitVar' no esta permitido aqui. Dentro de un run " +
               "con freno armado la unica identidad valida es $script:AgentTokenVar; el token del " +
               "dueno es admin y la regla de main lo exceptua, asi que aceptarlo devolveria justo " +
               "la capacidad que el freno quita.")
    }
    if ($ExplicitVar) {
        $v = Get-GhTokenValue -VarName $ExplicitVar
        if (-not $v) { throw "$ExplicitVar no esta en el entorno USER de Windows." }
        return @{ token = $v; var = $ExplicitVar; armed = $armed; reason = "override explicito ($ExplicitVar)" }
    }
    $agentPresent = [bool](Get-GhTokenValue -VarName $script:AgentTokenVar)
    $d = Resolve-GhTokenVar -IsArmed $armed -AgentTokenPresent $agentPresent -Owner $Owner -IdLookup $IdLookup
    if ($d.fail) { throw $d.reason }
    # An owner the map could not place is NEVER silent: the personal token is used, and the caller
    # is told so before it reaches a push error that would read as "no permission" (#665).
    if (-not $d.mapped) { Write-Warning $d.reason }
    $val = Get-GhTokenValue -VarName $d.var
    if (-not $val) { throw "$($d.var) no esta en el entorno USER de Windows." }
    return @{ token = $val; var = $d.var; armed = $armed; mapped = $d.mapped; reason = $d.reason }
}

# Read the variable's value. Kept separate from the DECISION so the decision stays pure - and so a
# token value never has to pass through the tested surface.
function Get-GhTokenValue {
    param([Parameter(Mandatory)][string]$VarName)
    if (-not $VarName) { return '' }
    return [System.Environment]::GetEnvironmentVariable($VarName, 'User')
}

# Dot-source guard: tests set $env:ABIOS_TOKENVAR_DOTSOURCE to load the pure core only.
if ($env:ABIOS_TOKENVAR_DOTSOURCE) { return }
