<#
.SYNOPSIS
    Decide WHICH GitHub identity applies here (#550, part of #541).

.DESCRIPTION
    There are three tokens in the Windows USER environment and they are not interchangeable:

      GITHUB_TOKEN_PERSONAL  CSalcedoDataBI          admin on the personal repos
      GITHUB_TOKEN_BUSINESS  PAL-Devs                20 repos, ADMIN on 17 - never for an agent
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
$script:OwnerTokenVar = @{
    'CSalcedoDataBI' = 'GITHUB_TOKEN_PERSONAL'
    'PAL-Devs'       = 'GITHUB_TOKEN_BUSINESS'
}

<#
    Which token variable applies for work starting at $StartDir?

    $IsArmed is passed IN rather than probed here so the decision stays pure and testable; callers
    use Brake-Guard's Read-BrakeMarker (or the fast probe) to establish it.

    $AgentTokenPresent likewise: whether the machine account's token actually exists in the
    environment. It is a parameter because the ANSWER WHEN IT IS MISSING is the interesting part -
    see below.

    Returns a hashtable: @{ var; reason; fail }.

      fail = $true means: an armed run has no agent identity available. The caller must STOP, not
      quietly continue as the owner. A silent fallback would hand the run exactly the identity the
      brake exists to keep away from it, while every message on screen still said "brake armed" -
      the precise shape of the defect this repo has now found in the brake (#440), the review gate
      (#510) and the evidence blocks (#479).
#>
function Resolve-GhTokenVar {
    param(
        [bool]$IsArmed = $false,
        [bool]$AgentTokenPresent = $false,
        [string]$Owner = 'CSalcedoDataBI'
    )
    $default = $script:OwnerTokenVar[$Owner]
    if (-not $default) { $default = 'GITHUB_TOKEN_PERSONAL' }

    if (-not $IsArmed) {
        return @{ var = $default; fail = $false
                  reason = "no es un run frenado - identidad normal ($default)" }
    }
    if (-not $AgentTokenPresent) {
        return @{ var = ''; fail = $true
                  reason = "run FRENADO y $script:AgentTokenVar no esta en el entorno. No se " +
                           "continua con el token del dueno: es admin y la regla de main lo " +
                           "exceptua, asi que seguir seria devolverle justo lo que el freno le quita." }
    }
    return @{ var = $script:AgentTokenVar; fail = $false
              reason = "run frenado - identidad de agente ($script:AgentTokenVar): sin admin, " +
                       "GitHub le rechaza el push a main" }
}

# The owner -> variable map, as a function so callers stop copying the literal. Four scripts each
# carried their own copy before #550; that is how one rule becomes four that disagree.
function Get-OwnerTokenVar {
    param([string]$Owner = 'CSalcedoDataBI')
    $v = $script:OwnerTokenVar[$Owner]
    if ($v) { return $v }
    return 'GITHUB_TOKEN_PERSONAL'
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
        [string]$Owner = 'CSalcedoDataBI'
    )
    $armed = Test-InBrakedRun -StartDir $StartDir
    $agentPresent = [bool](Get-GhTokenValue -VarName $script:AgentTokenVar)
    $d = Resolve-GhTokenVar -IsArmed $armed -AgentTokenPresent $agentPresent -Owner $Owner
    if ($d.fail) { throw $d.reason }
    $val = Get-GhTokenValue -VarName $d.var
    if (-not $val) { throw "$($d.var) no esta en el entorno USER de Windows." }
    return @{ token = $val; var = $d.var; armed = $armed; reason = $d.reason }
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
