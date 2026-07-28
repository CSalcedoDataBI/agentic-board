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

# Capture our own arguments BEFORE any dot-source. A dot-sourced script's param() block executes
# in THIS scope: Expert-RoleSynthesis declares $PlanGoal, so dot-sourcing it resets ours to "".
$myPlanText = $PlanText
$myPlanGoal = $PlanGoal
$myPath     = $Path

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
    [CmdletBinding()]
    param([string]$PlanText, [string]$PlanGoal, [string[]]$Inventory = @(), [hashtable]$Catalog)
    if (-not $Catalog) { $Catalog = Get-ExpertRoles }
    $domain  = Get-DomainFromPlan -Text $PlanText -Catalog $Catalog
    $role    = @($Catalog.roles) | Where-Object { $_.name -eq $domain } | Select-Object -First 1
    $hooked  = Get-HookedSkills -Domain $domain -Inventory $Inventory -Catalog $Catalog
    $persona = if ($role) { Resolve-RolePersona -Role $role } else { '' }
    $c = New-ExpertContract
    $c.role        = Format-RoleObjective -Domain $domain -HookedSkills $hooked -PlanGoal $PlanGoal -Persona $persona
    $c.roleMatched = ($domain -ne 'generic')
    if ($role -and $role.agent) { $c.roleAgent = [string]$role.agent }
    $c
}

# Dot-source guard: tests set $env:ABIOS_EXPERTCONFIG_DOTSOURCE to load the composition only.
if ($env:ABIOS_EXPERTCONFIG_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
$inventory = Resolve-SkillInventory

$contract = New-ExpertConfig -PlanText $myPlanText -PlanGoal $myPlanGoal -Inventory $inventory
$target = if ($myPath) { $myPath } else { Get-ExpertContractPath }

Write-Host "=== /board expert config ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Synthesized role (editable preview):" -ForegroundColor Cyan
Write-Host $contract.role -ForegroundColor Gray
Write-Host ""
if (-not $contract.roleMatched) {
    Write-Host "  NO ROLE MATCHED this plan - the expert would run as 'generic', with no domain toolset." -ForegroundColor Yellow
    Write-Host "  Research the plan's domain and propose a role, then persist it with:" -ForegroundColor DarkGray
    Write-Host "    Add-ExpertRole -Role @{ name='<domain>'; keywords=@(...); skills=@(...) }" -ForegroundColor DarkGray
    Write-Host "  Never write it without the user's confirmation: it changes how every future plan is classified." -ForegroundColor DarkGray
    Write-Host ""
}
$written = Write-ExpertContract -Contract $contract -Path $target
Write-Host "  OK  contract written -> $written" -ForegroundColor Green
Write-Host "      autonomy brakes only on: $($contract.autonomy.irreversible -join ', ')" -ForegroundColor DarkGray
Write-Host "      evidence -> PR + issue comment + versioned file" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next: review/edit the role, then run  /board expert auto <issue>" -ForegroundColor Cyan
