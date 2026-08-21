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

.PARAMETER PreferCodexRescue
    (#646) Opt into the stricter codex-rescue review path (Board-ReviewGate.ps1
    -PreferCodexRescue, #637/#644) for the run this contract configures — the CI-bot fallback
    stays the default when this is not passed. The skill asks the user this BEFORE passing it;
    this script does not prompt. Silently ignored (with a loud warning, never a silent write of
    `true`) when the `codex@openai-codex` plugin is not detected as installed — an unreachable
    opt-in would just make the review gate fail for a reason the run cannot fix itself.

.PARAMETER InstalledPlugins
    Injectable for tests: the lowercase plugin/marketplace identifiers `Get-InstalledPlugins.ps1`
    would have returned. Defaults to actually running it.

.EXAMPLE
    .\Expert-Config.ps1 -PlanText "Power BI Deneb visual" -PlanGoal "Ship a bar chart"
    .\Expert-Config.ps1 -PlanText "..." -PlanGoal "..." -PreferCodexRescue
#>
[CmdletBinding()]
param(
    [string]$PlanText = "",
    [string]$PlanGoal = "",
    [string]$Path = "",
    [switch]$Commit,
    [switch]$PreferCodexRescue,
    [string[]]$InstalledPlugins
)

$ErrorActionPreference = "Stop"

# Capture our own arguments BEFORE any dot-source. A dot-sourced script's param() block executes
# in THIS scope: Expert-RoleSynthesis declares $PlanGoal, so dot-sourcing it resets ours to "".
$myPlanText            = $PlanText
$myPlanGoal            = $PlanGoal
$myPath                = $Path
$myPreferCodexRescue   = [bool]$PreferCodexRescue
$myInstalledPluginsSet = $PSBoundParameters.ContainsKey('InstalledPlugins')
$myInstalledPlugins    = $InstalledPlugins

# Load the sibling pure cores with THEIR guards set, so dot-sourcing does not run their CLIs.
$prevC = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC

$prevR = $env:ABIOS_EXPERTROLE_DOTSOURCE
$env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-RoleSynthesis.ps1')
$env:ABIOS_EXPERTROLE_DOTSOURCE = $prevR

# (#646) Is `codex@openai-codex` installed? Pure given the plugin-id list Get-InstalledPlugins.ps1
# would have produced — kept separate so it is unit-testable without shelling out to `claude`.
function Test-CodexRescueAvailable {
    param([string[]]$InstalledPlugins = @())
    return [bool](@($InstalledPlugins) | Where-Object { "$_".ToLowerInvariant() -eq 'codex' })
}

# ── Pure core ───────────────────────────────────────────────────────────────────
function New-ExpertConfig {
    [CmdletBinding()]
    param(
        [string]$PlanText, [string]$PlanGoal, [string[]]$Inventory = @(), [hashtable]$Catalog,
        [bool]$PreferCodexRescue = $false, [string[]]$InstalledPlugins = @()
    )
    if (-not $Catalog) { $Catalog = Get-ExpertRoles }
    $domain  = Get-DomainFromPlan -Text $PlanText -Catalog $Catalog
    $role    = @($Catalog.roles) | Where-Object { $_.name -eq $domain } | Select-Object -First 1
    $hooked  = Get-HookedSkills -Domain $domain -Inventory $Inventory -Catalog $Catalog
    $persona = if ($role) { Resolve-RolePersona -Role $role } else { '' }
    $c = New-ExpertContract
    $c.role        = Format-RoleObjective -Domain $domain -HookedSkills $hooked -PlanGoal $PlanGoal -Persona $persona
    $c.roleMatched = ($domain -ne 'generic')
    if ($role -and $role.agent) { $c.roleAgent = [string]$role.agent }

    # (#646) Never silently write `true` when the run cannot actually reach codex-rescue — an
    # unreachable opt-in would fail the review gate for a reason the launched run has no way to
    # fix on its own. `codexRescueAvailable` is a computed signal (same pattern as `roleMatched`),
    # not a knob - it says whether the CLI request could be honoured, for `config`'s own printout.
    $available = Test-CodexRescueAvailable -InstalledPlugins $InstalledPlugins
    $c.review.preferCodexRescue = ($PreferCodexRescue -and $available)
    $c.codexRescueAvailable     = $available
    $c.codexRescueRequestedButUnavailable = ($PreferCodexRescue -and -not $available)
    $c
}

# Dot-source guard: tests set $env:ABIOS_EXPERTCONFIG_DOTSOURCE to load the composition only.
if ($env:ABIOS_EXPERTCONFIG_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
$inventory = Resolve-SkillInventory

if (-not $myInstalledPluginsSet) {
    $pl = Join-Path $PSScriptRoot 'Get-InstalledPlugins.ps1'
    $myInstalledPlugins = if (Test-Path $pl) { @(& $pl) } else { @() }
}

$contract = New-ExpertConfig -PlanText $myPlanText -PlanGoal $myPlanGoal -Inventory $inventory `
                              -PreferCodexRescue $myPreferCodexRescue -InstalledPlugins $myInstalledPlugins
$target = if ($myPath) { $myPath } else { Get-ExpertContractPath }

Write-Host "=== /board expert config ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Synthesized role (editable preview):" -ForegroundColor Cyan
Write-Host $contract.role -ForegroundColor Gray
Write-Host ""
if (-not $contract.roleMatched) {
    Write-Host "  NO ROLE MATCHED this plan - the expert would run as 'generic', with no domain toolset." -ForegroundColor Yellow
    Write-Host "  Research the plan's domain, propose a role to the user in plain language, and only" -ForegroundColor DarkGray
    Write-Host "  persist it once they confirm - it changes how every future plan is classified." -ForegroundColor DarkGray
    Write-Host ""
}
$written = Write-ExpertContract -Contract $contract -Path $target
Write-Host "  OK  contract written -> $written" -ForegroundColor Green
Write-Host "      autonomy brakes only on: $($contract.autonomy.irreversible -join ', ')" -ForegroundColor DarkGray
Write-Host "      evidence -> PR + issue comment + versioned file" -ForegroundColor DarkGray
# (#646) State the review-independence choice as plainly as the autonomy brakes above it - this
# is the one line meant to make the codex-rescue path discoverable to a human BEFORE launch,
# instead of only living in a reference doc nobody reads until something goes wrong.
if ($contract.codexRescueRequestedButUnavailable) {
    Write-Host "      independent review -> CI-bot fallback (you asked for the stricter path, but I can't turn it on yet - the extra reviewer isn't installed)" -ForegroundColor Yellow
} elseif ($contract.review.preferCodexRescue) {
    Write-Host "      independent review -> codex-rescue (disk-verified marker, #637/#644) - the run will be told to use it" -ForegroundColor DarkGray
} elseif ($contract.codexRescueAvailable) {
    Write-Host "      independent review -> CI-bot fallback (codex-rescue is installed and available - pass -PreferCodexRescue to opt in)" -ForegroundColor DarkGray
} else {
    Write-Host "      independent review -> CI-bot fallback (the default; codex-rescue is not installed)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Next: review/edit the role, then run  /board expert auto <issue>" -ForegroundColor Cyan
