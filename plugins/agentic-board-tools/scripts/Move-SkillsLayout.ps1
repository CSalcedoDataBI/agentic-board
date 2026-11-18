<#  Move-SkillsLayout.ps1 — reorganize scattered project skills into the canonical layout.

    Target layout (consumer repo / monorepo):
        <Root>/.claude/skills/<project>/<skill>/SKILL.md

    Scattered SKILL.md files (outside .claude/skills) are the "mess" this fixes. Each
    misplaced skill's whole directory is moved with `git mv` (history preserved) to
    .claude/skills/<project>/<skill>/, where <project> is the skill's top-level path
    segment (override per-skill with -Map @{ 'skill-name' = 'project' }). A
    skills-index.json is written for discovery. Nothing outside <Root> is ever touched
    — never the plugin cache, never ~/.claude/skills — so installed plugins keep working.

    SAFE BY DEFAULT: prints the from->to plan and changes NOTHING unless -Apply is given.
    -Apply requires a clean git tree (or -Force) so the single revert command below is
    exact:  git reset --hard HEAD ; git clean -fd <Root>/.claude/skills

    EXAMPLES
      .\Move-SkillsLayout.ps1 -Root .                 # dry-run plan
      .\Move-SkillsLayout.ps1 -Root . -Apply          # move + write index
      .\Move-SkillsLayout.ps1 -Root . -Map @{ 'loose-skill' = 'shared' } -Apply
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Apply,
    [switch]$Force,
    [hashtable]$Map = @{},
    [switch]$IndexOnly
)

$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot 'Get-SkillInventory.ps1'
if (-not (Test-Path $engine)) { throw "Get-SkillInventory.ps1 not found next to this script." }

$RootFull = (Resolve-Path -LiteralPath $Root).Path
$RootNorm = ($RootFull -replace '\\','/').TrimEnd('/')

function Invoke-Git {
    param([string[]]$GitArgs)
    Push-Location $RootFull
    try { & git @GitArgs } finally { Pop-Location }
}

# ── 1. Inventory (project scope) and compute the move plan ───────────────────────
$inv  = & $engine -Root $RootFull -Scope project
$plan = [System.Collections.Generic.List[object]]::new()
foreach ($s in $inv.skills) {
    if (-not $s.misplaced) { continue }   # only scattered skills are relocated
    $srcDir  = ($s.path -replace '/SKILL\.md$','')
    $proj    = if ($Map.ContainsKey($s.name)) { $Map[$s.name] } else { $s.project }
    if (-not $proj -or $proj -eq '(unpartitioned)') { $proj = 'shared' }
    $destDir = "$RootNorm/.claude/skills/$proj/$($s.name)"
    if ($srcDir -eq $destDir) { continue }
    $plan.Add([pscustomobject]@{ name=$s.name; project=$proj; from=$srcDir; to=$destDir })
}

$indexPath = "$RootNorm/.claude/skills/skills-index.json"

# ── 2. Report the plan ───────────────────────────────────────────────────────────
Write-Host "=== Move-SkillsLayout  $RootNorm ===" -ForegroundColor Cyan
if ($plan.Count -eq 0 -and -not $IndexOnly) {
    Write-Host "  Nothing to relocate — no misplaced skills found." -ForegroundColor Green
} else {
    foreach ($p in $plan) {
        Write-Host ("  MOVE  {0}" -f $p.name) -ForegroundColor Yellow
        Write-Host ("        from {0}" -f ($p.from -replace [regex]::Escape($RootNorm + '/'),''))
        Write-Host ("        to   {0}" -f ($p.to   -replace [regex]::Escape($RootNorm + '/'),''))
    }
}

# ── 3. Apply (guarded) ───────────────────────────────────────────────────────────
if ($Apply -and $plan.Count -gt 0) {
    $dirty = Invoke-Git @('status','--porcelain')
    if ($dirty -and -not $Force) {
        throw "Working tree is not clean. Commit/stash first, or pass -Force. Refusing to move files onto a dirty tree."
    }
    foreach ($p in $plan) {
        $destParent = Split-Path $p.to -Parent
        if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
        $rc = Invoke-Git @('mv', $p.from, $p.to)
        Write-Host ("  OK  moved {0} -> {1}" -f $p.name, ($p.to -replace [regex]::Escape($RootNorm + '/'),'')) -ForegroundColor Green
    }
}

# ── 4. Write the discovery index (from a fresh inventory after any moves) ─────────
if (($Apply -and $plan.Count -gt 0) -or $IndexOnly) {
    $inv2  = & $engine -Root $RootFull -Scope project
    $index = $inv2.skills | Where-Object { -not $_.misplaced } |
        Select-Object name, namespace, project,
            @{n='path';   e={ $_.path -replace [regex]::Escape($RootNorm + '/'),'' }},
            description | Sort-Object project, name
    $idxDir = Split-Path $indexPath -Parent
    if (-not (Test-Path $idxDir)) { New-Item -ItemType Directory -Path $idxDir -Force | Out-Null }
    ($index | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $indexPath -Encoding utf8
    Write-Host ("  OK  wrote {0} ({1} skills)" -f ($indexPath -replace [regex]::Escape($RootNorm + '/'),''), @($index).Count) -ForegroundColor Green
}

# ── 5. Revert hint ───────────────────────────────────────────────────────────────
if ($Apply -and $plan.Count -gt 0) {
    Write-Host ""
    Write-Host "Revert (clean tree required, so this is exact):" -ForegroundColor DarkCyan
    Write-Host "  git reset --hard HEAD ; git clean -fd `"$RootNorm/.claude/skills`"" -ForegroundColor DarkCyan
} elseif (-not $Apply -and $plan.Count -gt 0) {
    Write-Host ""
    Write-Host "Dry-run only. Re-run with -Apply to move (a clean git tree is required)." -ForegroundColor DarkCyan
}

# Emit the plan object for programmatic callers / tests.
[pscustomobject]@{ root=$RootNorm; applied=[bool]$Apply; moves=$plan; indexPath=$indexPath }
