<#
.SYNOPSIS
    /board expert `roles` — show the effective role catalog and explain how a plan matches.

.DESCRIPTION
    `-List` prints every role in precedence order with its source (factory / local / local
    overriding factory) and how many installed skills it actually hooks — the honest column: a
    role that hooks zero skills looks fine on paper and is useless in practice.
    `-Why "<plan text>"` prints the resolution trace: which roles were evaluated, in order, and
    which keyword in which role decided the match.

    Pure core behind a dot-source guard ($env:ABIOS_EXPERTROLESCMD_DOTSOURCE).

.EXAMPLE
    .\Expert-Roles.ps1 -List
    .\Expert-Roles.ps1 -Why "Build a Deneb bar chart"
#>
[CmdletBinding()]
param([switch]$List, [string]$Why = "")

$ErrorActionPreference = "Stop"

# Load the sibling cores with THEIR guards set, so dot-sourcing does not run their CLIs.
$prevRoles = $env:ABIOS_EXPERTROLES_DOTSOURCE
$env:ABIOS_EXPERTROLES_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertRolesIo.ps1')
$env:ABIOS_EXPERTROLES_DOTSOURCE = $prevRoles

$prevSyn = $env:ABIOS_EXPERTROLE_DOTSOURCE
$env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-RoleSynthesis.ps1')
$env:ABIOS_EXPERTROLE_DOTSOURCE = $prevSyn

# Capture our own arguments AFTER the dot-sources: a dot-sourced param() block runs in this
# scope, and Expert-RoleSynthesis declares $Text/$PlanGoal. Ours survive only because they are
# named differently — re-read them here so the CLI below cannot be surprised by a future clash.
$myList = $List
$myWhy  = $Why

# ── Pure core ───────────────────────────────────────────────────────────────────
function Get-RoleSource {
    [CmdletBinding()]
    param([hashtable]$Role, [hashtable]$Factory, [hashtable]$Local)
    $inFactory = @($Factory.roles.name) -contains $Role.name
    $inLocal   = @($Local.roles.name)   -contains $Role.name
    if ($inLocal -and $inFactory) { return 'local (overrides factory)' }
    if ($inLocal)                 { return 'local' }
    'factory'
}

function Get-RoleMatchTrace {
    [CmdletBinding()]
    param([string]$Text, [hashtable]$Catalog)
    $t = ($Text ?? '').ToLowerInvariant()
    $evaluated = [System.Collections.Generic.List[string]]::new()
    foreach ($role in @($Catalog.roles)) {
        $evaluated.Add($role.name) | Out-Null
        foreach ($kw in @($role.keywords)) {
            if ($kw -and $t.Contains(([string]$kw).ToLowerInvariant())) {
                return @{ role = $role.name; keyword = [string]$kw; evaluated = $evaluated.ToArray() }
            }
        }
    }
    @{ role = 'generic'; keyword = $null; evaluated = $evaluated.ToArray() }
}

# Dot-source guard: tests set $env:ABIOS_EXPERTROLESCMD_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTROLESCMD_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
$catalog = Get-ExpertRoles

if ($myWhy) {
    $trace = Get-RoleMatchTrace -Text $myWhy -Catalog $catalog
    Write-Host "=== /board expert roles why ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Evaluated (in precedence order): $($trace.evaluated -join ' -> ')" -ForegroundColor DarkGray
    if ($trace.keyword) {
        Write-Host "  MATCH  '$($trace.role)' on keyword '$($trace.keyword)'" -ForegroundColor Green
    } else {
        Write-Host "  NO MATCH - falling back to 'generic'." -ForegroundColor Yellow
        Write-Host "  Add a role in .agentic-board/roles.json, or run /board expert config to synthesize one." -ForegroundColor DarkGray
    }
    return
}

$factory   = Get-ExpertRoles -PresetPath (Get-ExpertRolePresetPath) -LocalPath '' -NoCache
$localRaw  = Read-ExpertRoleFile -Path (Get-ExpertRoleLocalPath)
$local     = if ($localRaw) { $localRaw } else { @{ roles = @() } }
$inventory = Resolve-SkillInventory

Write-Host "=== /board expert roles ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-22} {1,-26} {2,8} {3,7}" -f 'ROLE','SOURCE','KEYWORDS','HOOKS') -ForegroundColor DarkGray
foreach ($role in @($catalog.roles)) {
    $hooks  = @(Get-HookedSkills -Domain $role.name -Inventory $inventory -Catalog $catalog).Count
    $colour = if ($hooks -eq 0 -and @($role.keywords).Count -gt 0) { 'Yellow' } else { 'Gray' }
    Write-Host ("  {0,-22} {1,-26} {2,8} {3,7}" -f `
        $role.name, (Get-RoleSource -Role $role -Factory $factory -Local $local), `
        @($role.keywords).Count, $hooks) -ForegroundColor $colour
}
Write-Host ""
Write-Host "  Local catalog: $(Get-ExpertRoleLocalPath)" -ForegroundColor DarkGray
Write-Host "  A role hooking 0 skills will give the expert no toolset - fix its 'skills' patterns." -ForegroundColor DarkGray
