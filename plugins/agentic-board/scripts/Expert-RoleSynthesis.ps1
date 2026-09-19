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

# Pruned directory walker shared with Get-SkillInventory.ps1 (function only; runs nothing).
. (Join-Path $PSScriptRoot 'Find-FilesPruned.ps1')

# ── Pure core ───────────────────────────────────────────────────────────────────

function Get-DomainFromPlan {
    # Score-based: evaluate every role, sum the lengths of all matched keywords, and return the
    # highest-scoring role. Longer keywords are more specific and outweigh multiple short matches.
    # Ties are broken by catalog order (local-before-factory precedence is preserved).
    [CmdletBinding()]
    param([string]$Text, [hashtable]$Catalog)
    if (-not $Catalog) { $Catalog = Get-ExpertRoles }
    $t = ($Text ?? '').ToLowerInvariant()
    $best = $null; $bestScore = 0
    foreach ($role in @($Catalog.roles)) {
        $score = 0
        foreach ($kw in @($role.keywords)) {
            if ($kw -and $t.Contains(([string]$kw).ToLowerInvariant())) {
                $score += ([string]$kw).Length
            }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $role.name }
    }
    if ($best) { return $best }
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
        # Prefix-only: the leaf must start with the pattern so 'skill' matches 'skill-creator' and
        # 'skills-audit' but NOT 'example-skill' (where "skill" appears as a suffix).
        $leaf = ($s -split ':')[-1].ToLowerInvariant()
        foreach ($p in $patterns) {
            $pl = ([string]$p).ToLowerInvariant()
            if ($pl -and $leaf -match "^$([regex]::Escape($pl))") { $hooked.Add($s); break }
        }
    }
    # Always engage the quality profile where it is installed.
    foreach ($s in $inv) {
        $leaf = ($s -split ':')[-1]
        if ((@($Catalog.qualityProfile) -contains $leaf) -and (-not $hooked.Contains($s))) { $hooked.Add($s) }
    }
    $hooked.ToArray()
}

function Get-AgentFrontmatterName {
    # The Agent tool registers an agent under its frontmatter `name`, not its file name.
    param([string]$Path)
    try { $raw = [System.IO.File]::ReadAllText($Path) } catch { return $null }
    $fm = [regex]::Match($raw, '(?s)^\s*---\r?\n(.*?)\r?\n---')
    if (-not $fm.Success) { return $null }
    $n = [regex]::Match($fm.Groups[1].Value, '(?m)^name:\s*(.+?)\s*$')
    if ($n.Success) { return $n.Groups[1].Value.Trim('"', "'") }
    $null
}

function Get-AgentDefinitionIndex {
    # Every <root>/**/agents/*.md, indexed ONCE by frontmatter name and by file stem (with and
    # without the `.agent` suffix that `<stem>.agent.md` definitions carry). Roots are walked with
    # the pruned walker, so node_modules/ and friends cost nothing, and under a time budget so a
    # huge plugin cache can never hang the caller (#609). Candidates keep root order, so a project
    # definition still outranks the plugin cache.
    [CmdletBinding()]
    param([string[]]$SearchRoots, [double]$TimeoutSeconds = 30)
    $deadline = if ($TimeoutSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
    $byName = @{}; $byStem = @{}
    $walk = @{ Partial = $false }
    $add = {
        param($Table, [string]$Key, [string]$Path)
        if (-not $Key) { return }
        $k = $Key.ToLowerInvariant()
        if (-not $Table.ContainsKey($k)) { $Table[$k] = [System.Collections.Generic.List[string]]::new() }
        if (-not $Table[$k].Contains($Path)) { $Table[$k].Add($Path) }
    }
    foreach ($root in @($SearchRoots)) {
        if (-not $root) { continue }
        foreach ($file in @(Find-FilesPruned -Root $root -Filter '*.md' -UnderDirNamed 'agents' -Deadline $deadline -State $walk)) {
            $stem = [System.IO.Path]::GetFileName($file) -replace '\.md$', ''
            & $add $byStem $stem $file
            if ($stem -match '\.agent$') { & $add $byStem ($stem -replace '\.agent$', '') $file }
            & $add $byName (Get-AgentFrontmatterName -Path $file) $file
        }
    }
    # `partial` = the budget ran out before every root was fully read, so a MISS in this index means
    # "not found in what was scanned", never "not installed". Callers must not report it as absent.
    @{ byName = $byName; byStem = $byStem; partial = [bool]$walk.Partial }
}

function Find-AgentDefinition {
    # Resolves the name a user reads off the Agent tool's list to its definition file. Matching
    # order: frontmatter `name` (full, then without a 'plugin:' namespace), then file stem (with or
    # without `.agent`). A namespace is only a tie-breaker between candidates — a definition under
    # a directory named after it wins — never a reason to fail to resolve (#469).
    # Callers resolving several names can build the index once (Get-AgentDefinitionIndex) and pass
    # it as -Index instead of re-walking the roots per lookup.
    [CmdletBinding()]
    param([string]$Name, [string[]]$SearchRoots, [hashtable]$Index)
    if (-not $Name) { return $null }
    if (-not $Index) { $Index = Get-AgentDefinitionIndex -SearchRoots $SearchRoots }
    $parts = $Name -split ':'
    $leaf  = $parts[-1].ToLowerInvariant()
    $ns    = if ($parts.Count -gt 1) { $parts[0].ToLowerInvariant() } else { '' }
    foreach ($probe in @(
        @{ table = $Index.byName; key = $Name.ToLowerInvariant() },
        @{ table = $Index.byName; key = $leaf },
        @{ table = $Index.byStem; key = $leaf })) {
        $cands = $probe.table[$probe.key]
        if (-not $cands -or $cands.Count -eq 0) { continue }
        if ($ns) {
            $hit = @($cands) | Where-Object { ($_ -replace '\\', '/').ToLowerInvariant().Contains("/$ns/") } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        return $cands[0]
    }
    $null
}

function Get-DefaultAgentRoots {
    $userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }
    @(
        (Join-Path (Get-Location).Path '.claude'),
        (Split-Path $PSScriptRoot -Parent),
        (Join-Path $userHome '.claude/agents'),
        (Join-Path $userHome '.claude/plugins/cache')
    ) | Where-Object { $_ }
}

function Resolve-RolePersona {
    # A role's persona comes from an existing agent definition rather than restating one.
    # Inline standards are the shortcut for when no definition is worth creating.
    [CmdletBinding()]
    param([hashtable]$Role, [string[]]$SearchRoots, [hashtable]$Index)
    if (-not $SearchRoots) { $SearchRoots = Get-DefaultAgentRoots }
    if ($Role.agent) {
        $index = if ($Index) { $Index } else { Get-AgentDefinitionIndex -SearchRoots $SearchRoots }
        $path = Find-AgentDefinition -Name $Role.agent -Index $index
        if ($path) {
            # Drop the frontmatter block; the body is the persona.
            $raw = Get-Content -Raw -LiteralPath $path
            return ($raw -replace '(?s)^\s*---.*?---\s*', '').Trim()
        }
        if ($index.partial) {
            # A timed-out scan cannot prove absence: say so, and never point the user at /tools.
            Write-Warning "roles: role '$($Role.name)' names agent '$($Role.agent)', but the scan of installed agents ran out of time before it was found - it may be installed. The role falls back to its standards for now."
        } else {
            Write-Warning "roles: role '$($Role.name)' names agent '$($Role.agent)', which is not installed - install it with /tools, or the role falls back to its standards."
        }
    }
    if ($Role.standards) { return (@($Role.standards) -join "`n") }
    ''
}

function Format-RoleObjective {
    param([string]$Domain, [string[]]$HookedSkills, [string]$PlanGoal, [string]$Persona)
    # Drop empties before counting: @($null).Count is 1 in PowerShell, so a naive count check
    # skips the fallback and renders a bare "- " bullet.
    $list = @(@($HookedSkills) | Where-Object { $_ })
    $skillList = if ($list.Count) { ($list | ForEach-Object { "- $_" }) -join "`n" } else { "- (none installed — research the domain from scratch via /knowledge)" }
    $standards = if ($Persona) { $Persona } else {
@"
Your standards: you research prior-art before building (register findings via ``/knowledge``),
you build test-first, you record evidence of every test, and you never ship past a failing gate.
"@
    }
    @"
## Expert role (objective)

You are an **expert in $Domain**. Your objective for this task:

> $PlanGoal

$standards
Engage these installed skills as your working toolset:

$skillList
"@
}

# ── Inventory resolver (touches the filesystem; kept out of the pure core) ──────
function Resolve-SkillInventory {
    # Get-SkillInventory.ps1 is a SCRIPT emitting a {summary, skills, overlaps} object — there is
    # no Get-SkillInventory *function*. Invoke it with & and never dot-source it: a dot-sourced
    # param() block runs in THIS scope and would clobber same-named variables of the caller.
    [CmdletBinding()]
    param([string]$Root, [string]$Scope = 'all', [double]$TimeoutSeconds = 60)
    $inv = Join-Path $PSScriptRoot 'Get-SkillInventory.ps1'
    if (-not (Test-Path $inv)) { return @() }
    # Bound the walk: this feeds `config` and `roles -List`, which must never sit silent for
    # minutes on a large tree (#609). A run that hits the budget warns and returns what it found.
    $splat = @{ TimeoutSeconds = $TimeoutSeconds }
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
