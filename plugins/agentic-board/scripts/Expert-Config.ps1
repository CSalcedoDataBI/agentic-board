<#
.SYNOPSIS
    /board expert `config` — build the auto-expert contract with a synthesized role and persist it.

.DESCRIPTION
    The setup half of /board expert. It detects the plan's domain, hooks the installed
    skills/profiles for that domain, synthesizes the "role-as-objective", and writes a contract
    (defaults: brake only on the irreversible, evidence x3, board self-drive, budget). Executes
    nothing else — the contract is left reviewable for the user before `auto` consumes it.

    Pure composition (New-ExpertConfig) behind $env:ABIOS_EXPERTCONFIG_DOTSOURCE; it reuses the
    pure cores of ExpertContractIo.ps1 and Expert-RoleSynthesis.ps1 (dot-sourced with their own
    guards set, so their CLIs do not run).

.PARAMETER PlanText
    Text of the plan/epic the expert will work (used to detect the domain).

.PARAMETER PlanGoal
    The goal line that becomes the role objective.

.PARAMETER Path
    Where to write the contract. Default: the resolved .agentic-board/expert.json.

.PARAMETER Commit
    Reserved: version the contract instead of leaving it in gitignored state (handled by the
    caller/skill — this script only writes the file).

.EXAMPLE
    .\Expert-Config.ps1 -PlanText "Power BI Deneb visual" -PlanGoal "Ship a bar chart"
#>
[CmdletBinding()]
param(
    [string]$PlanText = "",
    [string]$PlanGoal = "",
    [string]$Path = "",
    [switch]$Commit
)

$ErrorActionPreference = "Stop"

# Load the sibling pure cores with THEIR guards set, so dot-sourcing does not run their CLIs.
$prevC = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC

$prevR = $env:ABIOS_EXPERTROLE_DOTSOURCE
$env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-RoleSynthesis.ps1')
$env:ABIOS_EXPERTROLE_DOTSOURCE = $prevR

# ── Pure core ───────────────────────────────────────────────────────────────────
function New-ExpertConfig {
    param([string]$PlanText, [string]$PlanGoal, [string[]]$Inventory = @())
    $domain = Get-DomainFromPlan -Text $PlanText
    $hooked = Get-HookedSkills -Domain $domain -Inventory $Inventory
    $role   = Format-RoleObjective -Domain $domain -HookedSkills $hooked -PlanGoal $PlanGoal
    $c = New-ExpertContract
    $c.role = $role
    $c
}

# Dot-source guard: tests set $env:ABIOS_EXPERTCONFIG_DOTSOURCE to load the composition only.
if ($env:ABIOS_EXPERTCONFIG_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
$inventory = @()
try {
    . (Join-Path $PSScriptRoot 'Get-SkillInventory.ps1')
    $inv = Get-SkillInventory 2>$null
    $inventory = @($inv | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.name) { $_.name } })
} catch { $inventory = @() }

$contract = New-ExpertConfig -PlanText $PlanText -PlanGoal $PlanGoal -Inventory $inventory
$target = if ($Path) { $Path } else { Get-ExpertContractPath }

Write-Host "=== /board expert config ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Synthesized role (editable preview):" -ForegroundColor Cyan
Write-Host $contract.role -ForegroundColor Gray
Write-Host ""
$written = Write-ExpertContract -Contract $contract -Path $target
Write-Host "  OK  contract written -> $written" -ForegroundColor Green
Write-Host "      autonomy brakes only on: $($contract.autonomy.irreversible -join ', ')" -ForegroundColor DarkGray
Write-Host "      evidence -> PR + issue comment + versioned file" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next: review/edit the role, then run  /board expert auto <issue>" -ForegroundColor Cyan
