<#
.SYNOPSIS
    Autonomy gate for /board expert — decide whether an action is irreversible (stop for the
    human) or safe to perform autonomously.

.DESCRIPTION
    The auto-expert runs unattended and brakes ONLY on the irreversible: merge to main, deploy,
    Fabric refresh, publish externally, delete. Everything else — research, build, test, create
    issues, open PRs, triage, handoff — it does on its own and records.

    Fail-safe by design: an action the gate does not recognize is treated as IRREVERSIBLE
    (stop and ask), never waved through. A new dangerous verb is safe-by-default until it is
    explicitly listed as safe.

    Pure (no side effects) behind a dot-source guard ($env:ABIOS_EXPERTAUTONOMY_DOTSOURCE).

.EXAMPLE
    . .\Expert-Autonomy.ps1 ; Test-IsIrreversible -Action 'merge' -Contract $contract
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# The explicitly-safe actions the auto-expert may perform without asking. Anything NOT here
# and NOT in the contract's irreversible list is unknown -> treated as irreversible (fail-safe).
$script:KnownSafe = @(
    'research','build','test','lint','commit','branch','push',
    'create-issue','issue','open-pr','pr','triage','handoff','scan',
    'knowledge','skills','comment','report','plan','worktree','fill','move'
)

function Test-IsIrreversible {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][hashtable]$Contract
    )
    $a = $Action.Trim().ToLowerInvariant()
    $irreversible = @()
    if ($Contract.autonomy -and $Contract.autonomy.irreversible) {
        $irreversible = @($Contract.autonomy.irreversible | ForEach-Object { "$_".ToLowerInvariant() })
    }
    if ($irreversible -contains $a) { return $true }
    if ($script:KnownSafe -contains $a) { return $false }
    # Unknown action -> fail safe: stop and ask.
    return $true
}

# Dot-source guard: tests set $env:ABIOS_EXPERTAUTONOMY_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTAUTONOMY_DOTSOURCE) { return }

# CLI: classify an action passed as the first argument against the resolved contract.
$cliAction = if ($args.Count -ge 1) { "$($args[0])" } else { "" }
if ($cliAction) {
    . (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
    $contract = Read-ExpertContract
    $verdict = Test-IsIrreversible -Action $cliAction -Contract $contract
    [pscustomobject]@{ action = $cliAction; irreversible = $verdict } | ConvertTo-Json
}
