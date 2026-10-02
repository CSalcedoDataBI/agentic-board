<#
.SYNOPSIS
    Decide WHICH GitHub identity applies here (#550, part of #541).

.DESCRIPTION
    A user may hold several GitHub identities, and they are not interchangeable: an owner account
    that is admin on its repositories, perhaps a work account with wider reach, and optionally a
    machine account for autonomous runs (write, no admin). WHICH env var holds which identity is the
    user's own map, ~/.agentic-board/accounts.json, written by `/board setup` and read through
    Get-AbiosAccounts.ps1 (#762). Nothing account-specific ships in this file. With no map, every
    owner resolves to the ambient token (GH_TOKEN, then `gh auth token`).

    WHY THIS FILE EXISTS. The autonomy brake could never be complete as a text classifier: it
    decides what a shell command WILL DO by looking at its characters, and the space of harmless
    commands is unbounded. Eleven of the nineteen defects found on 2026-07-31 were that same defect
    in different clothes.

    The capability side is different in kind. `main` requires a pull request, but the ruleset
    bypasses the repository ADMIN ROLE - and a PAT authenticates AS ITS OWNER, so any token of his
    walks straight through. Weaker permissions do not help: GitHub cannot tell "the human typed
    this" from "an agent used the human's token", because they are the same principal. Only a
    DIFFERENT identity gets a different answer. Measured, not argued:

        PATCH .../git/refs/heads/main  as the machine account
        -> Repository rule violations found. Changes must be made through a pull request. (422)
        POST  .../git/refs (ordinary branch)  as the same identity
        -> 200 OK

    So inside a brake-armed worktree the answer is the agent identity, and everywhere else it is
    the account default. Pure (no filesystem writes, no network) behind a dot-source guard.

    STATED LIMIT, because this repo keeps paying for overclaiming: this decides which variable the
    TOOLING reads. A run that ignores it and reads the owner's token variable itself is
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

# The user's account map (#762): owner login -> token variable, account ID -> token variable (the
# rename-proof key: a login can change, the numeric ID cannot), CLI alias -> login, and the agent
# identity's variable. Loaded from ~/.agentic-board/accounts.json; empty when the user has none.
. (Join-Path $PSScriptRoot 'Get-AbiosAccounts.ps1')
function Import-AbiosAccountMaps {
    param([object]$Config = (Get-AbiosAccountConfig))
    $script:AbiosAccountConfig = $Config
    $script:AgentTokenVar      = $Config.agentTokenVar
    $script:OwnerTokenVar      = $Config.owners
    $script:AccountIdTokenVar  = $Config.accountIds
    $script:AccountAlias       = $Config.aliases
    $script:DefaultOwner       = $Config.defaultOwner
}
Import-AbiosAccountMaps

# The variable an owner the map does not know falls back to: the default owner's own variable when
# the map names one, else GH_TOKEN - the ambient token, which Get-GhTokenValue reads as GH_TOKEN
# and then `gh auth token`. Never another mapped (possibly wider) identity.
function Get-FallbackTokenVar {
    if ($script:DefaultOwner -and $script:OwnerTokenVar.ContainsKey($script:DefaultOwner)) {
        return $script:OwnerTokenVar[$script:DefaultOwner]
    }
    return 'GH_TOKEN'
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
        [string]$Owner = '',
        [scriptblock]$IdLookup
    )
    if (-not $IsArmed) {
        $res = Resolve-OwnerTokenVar -Owner $Owner -IdLookup $IdLookup
        $why = if ($res.mapped) { "not a braked run - normal identity ($($res.var))" }
               else             { $res.reason }
        return @{ var = $res.var; fail = $false; mapped = $res.mapped; reason = $why }
    }
    if (-not $AgentTokenPresent) {
        return @{ var = ''; fail = $true; mapped = $true
                  reason = "BRAKED run and $script:AgentTokenVar is not in the environment. Not " +
                           "continuing with the owner's token: it is admin and the main rule " +
                           "exempts it, so continuing would hand back exactly what the brake takes away." }
    }
    return @{ var = $script:AgentTokenVar; fail = $false; mapped = $true
              reason = "braked run - agent identity ($script:AgentTokenVar): no admin, " +
                       "GitHub rejects its push to main" }
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
                         -What "resolve the account ID of '$Owner'"
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
        [string]$Owner = '',
        [scriptblock]$IdLookup
    )
    if (-not $Owner) { $Owner = $script:DefaultOwner }
    if ($script:OwnerTokenVar.Count -eq 0 -and $script:AccountIdTokenVar.Count -eq 0) {
        # No account map at all: the ordinary single-account setup. Not a warning - it is the
        # default for anyone who never ran /board setup.
        return @{ var = 'GH_TOKEN'; mapped = $true; how = 'ambient'
                  reason = "no account map ($((Get-AbiosAccountsPath))) - using the ambient token (GH_TOKEN, then gh auth token)" }
    }
    if ($Owner -and $script:OwnerTokenVar.ContainsKey($Owner)) {
        $v = $script:OwnerTokenVar[$Owner]
        return @{ var = $v; mapped = $true; how = 'login'
                  reason = "owner '$Owner' is in the map ($v)" }
    }
    $known = (@($script:OwnerTokenVar.Keys) | Sort-Object) -join ', '
    $note  = ''
    if ($Owner -and $IdLookup) {
        $id = ''
        try { $id = "$(& $IdLookup $Owner)".Trim() } catch { $id = '' }
        if ($id -and $script:AccountIdTokenVar.ContainsKey($id)) {
            $v = $script:AccountIdTokenVar[$id]
            return @{ var = $v; mapped = $true; how = 'account-id'
                      reason = "owner '$Owner' is not in the map by login, but its account ID " +
                               "($id) belongs to a known account ($v): it was renamed. Add the " +
                               "new login with /board setup." }
        }
        $note = if ($id) { " Its account ID ($id) does not belong to any known account either." }
                else     { ' Could not look up its account ID on GitHub.' }
    }
    $fb = Get-FallbackTokenVar
    return @{ var = $fb; mapped = $false; how = 'unmapped'
              reason = "owner '$Owner' is not mapped to any known account ($known).$note " +
                       "$fb is used by default. This is a problem of the " +
                       "owner->token MAP, not of permissions: if that account was renamed, add its login " +
                       "with /board setup or pass -TokenVar." }
}

function Get-OwnerTokenVar {
    param(
        [string]$Owner = '',
        # Default: ask GitHub for the account ID of a login the map does not know (a renamed
        # account). Tests pass a fake.
        [scriptblock]$IdLookup = { param($o) Get-OwnerAccountId -Owner $o }
    )
    $r = Resolve-OwnerTokenVar -Owner $Owner -IdLookup $IdLookup
    if (-not $r.mapped) { Write-Warning $r.reason }
    return $r.var
}

# A CLI alias from the user's map -> current login. '' when the alias is unknown.
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
        [string]$Owner = '',
        # A caller's explicit -TokenVar. Passed IN rather than handled by the caller, so the armed
        # check cannot be skipped by taking a different branch - which is exactly how the first cut
        # of this leaked (review round 2).
        [string]$ExplicitVar = '',
        # Seam for tests; the default asks GitHub, and only for an owner the map does not know.
        [scriptblock]$IdLookup = { param($o) Get-OwnerAccountId -Owner $o }
    )
    $armed = Test-InBrakedRun -StartDir $StartDir
    if (-not (Test-ExplicitVarAllowed -IsArmed $armed -ExplicitVar $ExplicitVar)) {
        throw ("BRAKED run: -TokenVar '$ExplicitVar' is not allowed here. Inside a run " +
               "with the brake armed the only valid identity is $script:AgentTokenVar; the owner's " +
               "token is admin and the main rule exempts it, so accepting it would hand back exactly " +
               "the capability the brake removes.")
    }
    if ($ExplicitVar) {
        # An explicit -TokenVar is a demand for THAT identity: a missing one is an error, never a
        # silent fallback to the ambient token (#499).
        $v = Get-GhTokenValue -VarName $ExplicitVar -NoAmbient
        if (-not $v) { throw "$ExplicitVar is not set (user or process environment); an explicit -TokenVar never falls back to another token." }
        return @{ token = $v; var = $ExplicitVar; armed = $armed; reason = "explicit override ($ExplicitVar)" }
    }
    $agentPresent = [bool](Get-GhTokenValue -VarName $script:AgentTokenVar)
    $d = Resolve-GhTokenVar -IsArmed $armed -AgentTokenPresent $agentPresent -Owner $Owner -IdLookup $IdLookup
    if ($d.fail) { throw $d.reason }
    # An owner the map could not place is NEVER silent: the personal token is used, and the caller
    # is told so before it reaches a push error that would read as "no permission" (#665).
    if (-not $d.mapped) { Write-Warning $d.reason }
    $val = Get-GhTokenValue -VarName $d.var
    if (-not $val) {
        if ($d.var -eq 'GH_TOKEN') { throw "No GitHub token: GH_TOKEN is unset and 'gh auth token' returned nothing. Run 'gh auth login', or map the account with /board setup." }
        throw "$($d.var) is not set (user or process environment). Set it, or change the map with /board setup."
    }
    return @{ token = $val; var = $d.var; armed = $armed; mapped = $d.mapped; reason = $d.reason }
}

# Read the variable's value. Kept separate from the DECISION so the decision stays pure - and so a
# token value never has to pass through the tested surface.
# The agent identity never falls back to the ambient token: a braked run with no agent token must
# stop, not continue as the owner (#550). Every other variable may (#762: cross-platform, and no
# registry required).
function Get-GhTokenValue {
    param([Parameter(Mandatory)][string]$VarName, [switch]$NoAmbient)
    if (-not $VarName) { return '' }
    $ambient = (-not $NoAmbient) -and ($VarName -ne $script:AgentTokenVar)
    return (Get-AbiosTokenValue -VarName $VarName -AllowAmbient:$ambient)
}

# Dot-source guard: tests set $env:ABIOS_TOKENVAR_DOTSOURCE to load the pure core only.
if ($env:ABIOS_TOKENVAR_DOTSOURCE) { return }
