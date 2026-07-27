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

# ── Pure core ───────────────────────────────────────────────────────────────────

# Domain keyword map. Order = precedence: the first domain with a keyword hit wins, so the
# more specific BI domains are checked before the broad 'extension' catch.
$script:DomainKeywords = [ordered]@{
    'powerbi-report'  = @('deneb','visual','chart','dashboard','report','pbir','svg')
    'semantic-model'  = @('tmdl','dax','measure','semantic model','tabular','bpa','relationship')
    'fabric'          = @('fabric','lakehouse','warehouse','pipeline','notebook','spark','eventhouse')
    'extension'       = @('extension','plugin','cli','command','vs code','vscode')
}

# Domain -> skill-name patterns to hook from the installed inventory.
$script:DomainSkillPatterns = @{
    'powerbi-report' = @('report','deneb','pbi','svg-visuals','python-visuals','r-visuals','theme')
    'semantic-model' = @('semantic-model','tmdl','dax','tabular','bpa','power-query','lineage')
    'fabric'         = @('fabric','spark','warehouse','lakehouse','eventhouse','dataflow','activator')
    'extension'      = @('frontend-design','skill','writing-skills')
    'generic'        = @()
}

# The quality profile — always engaged, whatever the domain (good engineering hygiene).
$script:QualityProfile = @('skill-creator','writing-skills','skill-improver','second-opinion')

function Get-DomainFromPlan {
    param([string]$Text)
    $t = ($Text ?? '').ToLowerInvariant()
    foreach ($domain in $script:DomainKeywords.Keys) {
        foreach ($kw in $script:DomainKeywords[$domain]) {
            if ($t.Contains($kw)) { return $domain }
        }
    }
    'generic'
}

function Get-HookedSkills {
    param([string]$Domain, [string[]]$Inventory)
    $inv = @($Inventory)
    $patterns = @($script:DomainSkillPatterns[$Domain])
    $hooked = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $inv) {
        foreach ($p in $patterns) {
            if ($s.ToLowerInvariant().Contains($p.ToLowerInvariant())) { $hooked.Add($s); break }
        }
    }
    # Always engage the quality profile where it is installed.
    foreach ($s in $inv) {
        $leaf = ($s -split ':')[-1]
        if (($script:QualityProfile -contains $leaf) -and (-not $hooked.Contains($s))) { $hooked.Add($s) }
    }
    $hooked.ToArray()
}

function Format-RoleObjective {
    param([string]$Domain, [string[]]$HookedSkills, [string]$PlanGoal)
    $skillList = if (@($HookedSkills).Count) { (@($HookedSkills) | ForEach-Object { "- $_" }) -join "`n" } else { "- (none installed — research the domain from scratch via /knowledge)" }
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

# Dot-source guard: tests set $env:ABIOS_EXPERTROLE_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTROLE_DOTSOURCE) { return }

# ── CLI: synthesize the role from the live inventory ────────────────────────────
$domain = Get-DomainFromPlan -Text $Text
$inventory = @()
try {
    . (Join-Path $PSScriptRoot 'Get-SkillInventory.ps1')
    $inv = Get-SkillInventory 2>$null
    $inventory = @($inv | ForEach-Object { if ($_ -is [string]) { $_ } elseif ($_.name) { $_.name } })
} catch { $inventory = @() }
$hooked = Get-HookedSkills -Domain $domain -Inventory $inventory
Format-RoleObjective -Domain $domain -HookedSkills $hooked -PlanGoal $PlanGoal
