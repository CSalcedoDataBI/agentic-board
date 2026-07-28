<#
.SYNOPSIS
    Role synthesis for /board expert — map a plan to a domain, hook the relevant installed
    skills/profiles, and render the "role-as-objective" block the auto-expert adopts.

.DESCRIPTION
    Hybrid role synthesis: the launched agent does the real prior-art RESEARCH (via /knowledge,
    docs MCPs, web); this script provides the deterministic, reproducible skeleton it fills in —
    which domain the plan is about, which already-installed skills/profiles to engage for that
    domain (reuse over reinvention), and the role objective text.

    Pure (no gh) behind a dot-source guard ($env:ABIOS_EXPERTROLE_DOTSOURCE) for unit tests;
    the CLI resolves the live skill inventory via Get-SkillInventory.ps1.

.EXAMPLE
    . .\Expert-RoleSynthesis.ps1 ; Get-DomainFromPlan -Text 'Power BI Deneb visual'
#>
[CmdletBinding()]
param(
    [string]$Text = "",
    [string]$PlanGoal = ""
)

$ErrorActionPreference = "Stop"

# The role catalog lives in files, not here. Load the reader with ITS guard set so dot-sourcing
# does not run its CLI.
$prevRoles = $env:ABIOS_EXPERTROLES_DOTSOURCE
$env:ABIOS_EXPERTROLES_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertRolesIo.ps1')
$env:ABIOS_EXPERTROLES_DOTSOURCE = $prevRoles

# ── Pure core ───────────────────────────────────────────────────────────────────

function Get-DomainFromPlan {
    # Order is precedence: local roles first, then factory, most specific first within each.
    [CmdletBinding()]
    param([string]$Text, [hashtable]$Catalog)
    if (-not $Catalog) { $Catalog = Get-ExpertRoles }
    $t = ($Text ?? '').ToLowerInvariant()
    foreach ($role in @($Catalog.roles)) {
        foreach ($kw in @($role.keywords)) {
            if ($kw -and $t.Contains(([string]$kw).ToLowerInvariant())) { return $role.name }
        }
    }
    'generic'
}

function Get-HookedSkills {
    [CmdletBinding()]
    param([string]$Domain, [string[]]$Inventory, [hashtable]$Catalog)
    if (-not $Catalog) { $Catalog = Get-ExpertRoles }
    # Dedup: worktrees and nested checkouts make the scanner report the same skill repeatedly.
    $inv  = @(@($Inventory) | Where-Object { $_ } | Select-Object -Unique)
    $role = @($Catalog.roles) | Where-Object { $_.name -eq $Domain } | Select-Object -First 1
    $patterns = @($role.skills)
    $hooked = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $inv) {
        # Match the skill NAME, never the plugin namespace that ships it — otherwise a broad
        # pattern like 'skill' hooks every skill of a plugin merely named "skills-for-*".
        $leaf = ($s -split ':')[-1].ToLowerInvariant()
        foreach ($p in $patterns) {
            if ($p -and $leaf.Contains(([string]$p).ToLowerInvariant())) { $hooked.Add($s); break }
        }
    }
    # Always engage the quality profile where it is installed.
    foreach ($s in $inv) {
        $leaf = ($s -split ':')[-1]
        if ((@($Catalog.qualityProfile) -contains $leaf) -and (-not $hooked.Contains($s))) { $hooked.Add($s) }
    }
    $hooked.ToArray()
}

function Format-RoleObjective {
    param([string]$Domain, [string[]]$HookedSkills, [string]$PlanGoal)
    # Drop empties before counting: @($null).Count is 1 in PowerShell, so a naive count check
    # skips the fallback and renders a bare "- " bullet.
    $list = @(@($HookedSkills) | Where-Object { $_ })
    $skillList = if ($list.Count) { ($list | ForEach-Object { "- $_" }) -join "`n" } else { "- (none installed — research the domain from scratch via /knowledge)" }
    @"
## Expert role (objective)

You are an **expert in $Domain**. Your objective for this task:

> $PlanGoal

Your standards: you research prior-art before building (register findings via ``/knowledge``),
you build test-first, you record evidence of every test, and you never ship past a failing gate.
Engage these installed skills as your working toolset:

$skillList
"@
}

# ── Inventory resolver (touches the filesystem; kept out of the pure core) ──────
function Resolve-SkillInventory {
    # Get-SkillInventory.ps1 is a SCRIPT emitting a {summary, skills, overlaps} object — there is
    # no Get-SkillInventory *function*. Invoke it with & and never dot-source it: a dot-sourced
    # param() block runs in THIS scope and would clobber same-named variables of the caller.
    param([string]$Root, [string]$Scope = 'all')
    $inv = Join-Path $PSScriptRoot 'Get-SkillInventory.ps1'
    if (-not (Test-Path $inv)) { return @() }
    $splat = @{}
    if ($Root)  { $splat.Root  = $Root }
    if ($Scope) { $splat.Scope = $Scope }
    try { $result = & $inv @splat } catch { return @() }
    @(@($result.skills) |
        ForEach-Object { if ($_.namespace) { $_.namespace } elseif ($_.name) { $_.name } } |
        Where-Object { $_ })
}

# Dot-source guard: tests set $env:ABIOS_EXPERTROLE_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTROLE_DOTSOURCE) { return }

# ── CLI: synthesize the role from the live inventory ────────────────────────────
$domain = Get-DomainFromPlan -Text $Text
$hooked = Get-HookedSkills -Domain $domain -Inventory (Resolve-SkillInventory)
Format-RoleObjective -Domain $domain -HookedSkills $hooked -PlanGoal $PlanGoal
