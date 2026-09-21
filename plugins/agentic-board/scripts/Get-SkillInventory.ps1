<#  Get-SkillInventory.ps1 — read-only inventory of Agent Skills across the 3 scopes.

    Enumerates every SKILL.md in:
      - plugin   : ~/.claude/plugins/**/skills/<skill>/SKILL.md   (namespace plugin:skill)
      - personal : ~/.claude/skills/<skill>/SKILL.md
      - project  : <Root>/.claude/skills/**/SKILL.md  AND any misplaced SKILL.md in the repo

    For each skill it parses the YAML frontmatter (name, description) and computes a
    description lint (the routing surface), a budget proxy (Claude Code's `doctor`
    health view is a terminal dialog we cannot invoke, so we approximate it with the
    documented 1536-char per-skill cap), the inferred monorepo project, and whether the
    file is misplaced (outside .claude/skills). It also flags near-duplicate skills by
    description keyword overlap (Jaccard) — the main disambiguation lever between neighbors.
    Copies of ONE skill (same name, same description, e.g. repo tree + plugin cache) are folded
    into one before comparing and counted in summary.collapsedCopies; two copies of one name
    whose descriptions differ are reported as kind 'divergent-copy' (a stale copy).

    Deterministic and side-effect free: it reads files and emits objects (or JSON).
    Everything else in skills-ops consumes this contract.

    EXAMPLES
      .\Get-SkillInventory.ps1 -Scope project -Root . -Json
      .\Get-SkillInventory.ps1 | Where-Object { $_.misplaced }
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [ValidateSet('all','plugin','personal','project')][string]$Scope = 'all',
    [double]$OverlapThreshold = 0.5,
    [switch]$Json,
    # Wall-clock budget for walking EACH scope (project, personal, plugins). When it runs out that
    # walk stops, warns, and the inventory is partial rather than the run hanging. 0 = no limit.
    [double]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Find-FilesPruned.ps1')

# Dirs we never descend into when hunting for stray SKILL.md files.
$ExcludeDirs = @('node_modules','.git','dist','build','vendor','bin','obj','out','.next','coverage')
$DescCap     = 1536   # documented per-skill description cap (proxy for `doctor`)
$StopWords   = @('the','and','for','use','when','with','that','this','from','into','your','skill',
                 'user','asks','want','wants','need','needs','a','an','to','of','in','on','or','is',
                 'it','be','are','you','can','via','not','but','has','had','als','del','los','las',
                 'una','uno','por','con','que','para','como') | ForEach-Object { $_ } | Sort-Object -Unique

function Get-Frontmatter {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $m = [regex]::Match($raw, '(?s)^﻿?---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return [pscustomobject]@{ name=$null; description=$null; bodyLines=($raw -split "\n").Count } }
    $fm = $m.Groups[1].Value
    $lines = $fm -split "\r?\n"
    $name = $null; $desc = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^name:\s*(.+?)\s*$')        { $name = $Matches[1].Trim('"',"'") ; continue }
        if ($ln -match '^description:\s*(.*)$') {
            $val = $Matches[1].Trim()
            # Folded/continued description: absorb following indented lines that are not a new key.
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s+\S' -and $lines[$j] -notmatch '^\S') {
                $val = ($val.TrimEnd() + ' ' + $lines[$j].Trim()); $j++
            }
            $desc = $val.Trim().Trim('>','|').Trim().Trim('"',"'")
        }
    }
    $bodyLines = (($raw.Substring($m.Index + $m.Length)) -split "\n").Count
    [pscustomobject]@{ name = $name; description = $desc; bodyLines = $bodyLines }
}

function Get-Lint {
    param([string]$Description)
    $d = if ($Description) { $Description } else { '' }
    $len = $d.Length
    [pscustomobject]@{
        thirdPerson    = ($d -notmatch '(?i)\b(I can|I will|I''ll|I help|let me|we help)\b') -and ($len -gt 0)
        # A "Triggers" clause is the word followed by a colon or a dash, with optional space BEFORE
        # the punctuation ("Triggers — a, b" is how this repo's own skills write it). A bare hyphen
        # must have a space after it, so "trigger-happy" and prose like "Triggers happen when..."
        # do not count.
        hasTriggers    = [bool]($d -match '(?i)(use when|use to|use for|\btriggers?\b(\s*[:—–]|\s*-\s)|when the user|when you)')
        useCaseFirst   = [bool]($d -match '(?i)^(use )?[a-z]+(s|es|es)?\b') -or ($len -gt 0 -and $d -match '^[A-Z]')
        hasWhenNotToUse= [bool]($d -match '(?i)(not for|do ?n[o'']t use|don''t use|NOT use|except when|rather than)')
        lenOk          = ($len -le $DescCap -and $len -gt 0)
    }
}

function Get-Keywords {
    param([string]$Text)
    if (-not $Text) { return @() }
    ($Text.ToLower() -split '[^a-z0-9]+') |
        Where-Object { $_.Length -gt 3 -and $StopWords -notcontains $_ } |
        Sort-Object -Unique
}

function New-SkillRecord {
    param([string]$Path, [string]$SkillScope, [string]$PluginName, [string]$RootPath)

    $fm   = Get-Frontmatter -Path $Path
    $desc = if ($fm) { $fm.description } else { $null }
    $nm   = if ($fm -and $fm.name) { $fm.name } else { Split-Path (Split-Path $Path -Parent) -Leaf }

    # Normalize to forward slashes for stable inference/output.
    $norm = ($Path -replace '\\','/')
    $misplaced = $false
    $project   = $null
    if ($SkillScope -eq 'project') {
        $rel = $norm
        if ($RootPath) { $rel = $norm.Replace((($RootPath -replace '\\','/').TrimEnd('/') + '/'), '') }
        $canon    = [regex]::Match($rel, '(?i)\.claude/skills/(.+)/SKILL\.md$')
        $pluginSrc= [regex]::Match($rel, '(?i)(?:^|/)plugins/([^/]+)/skills/[^/]+/SKILL\.md$')
        if ($canon.Success) {
            # Consumer layout: .claude/skills/<project>/<skill>/SKILL.md
            $segs = $canon.Groups[1].Value -split '/'
            $project = if ($segs.Count -ge 2) { $segs[0] } else { '(unpartitioned)' }
        } elseif ($pluginSrc.Success) {
            # Plugin-source layout: plugins/<plugin>/skills/<skill>/SKILL.md — canonical, not misplaced.
            $project = $pluginSrc.Groups[1].Value
        } else {
            $misplaced = $true
            $project   = (($rel -split '/') | Select-Object -First 1)
        }
    }

    $ns = if ($SkillScope -eq 'plugin' -and $PluginName) { "$PluginName`:$nm" } else { $nm }

    [pscustomobject]@{
        name        = $nm
        scope       = $SkillScope
        plugin      = $PluginName
        namespace   = $ns
        path        = $norm
        project     = $project
        misplaced   = $misplaced
        description = $desc
        descChars   = if ($desc) { $desc.Length } else { 0 }
        bodyLines   = if ($fm) { $fm.bodyLines } else { 0 }
        hasName     = [bool]$nm -and [bool]($fm -and $fm.name)
        lint        = (Get-Lint -Description $desc)
        budget      = [pscustomobject]@{
                          descChars = if ($desc) { $desc.Length } else { 0 }
                          overCap   = [bool]($desc -and $desc.Length -gt $DescCap)
                      }
        _keywords   = (Get-Keywords -Text $desc)
    }
}

function Find-SkillFiles {
    # Pruned walk: the excluded directories are never entered (they used to be walked in full and
    # filtered afterwards, which is what made a repo with a big node_modules/ crawl). Each base gets
    # its own -TimeoutSeconds budget, so one pathological tree cannot starve the other scopes.
    param([string]$Base)
    $deadline = if ($TimeoutSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
    @(Find-FilesPruned -Root $Base -Filter 'SKILL.md' -ExcludeDirs $ExcludeDirs -Deadline $deadline) |
        ForEach-Object { [pscustomobject]@{ FullName = $_ } }
}

# ── Collect ────────────────────────────────────────────────────────────────────
$records  = [System.Collections.Generic.List[object]]::new()
$userHome = $env:USERPROFILE; if (-not $userHome) { $userHome = $HOME }

if ($Scope -in @('all','project')) {
    foreach ($f in (Find-SkillFiles -Base $Root)) {
        $records.Add((New-SkillRecord -Path $f.FullName -SkillScope 'project' -PluginName $null -RootPath $Root))
    }
}
if ($Scope -in @('all','personal')) {
    $pbase = Join-Path $userHome '.claude/skills'
    foreach ($f in (Find-SkillFiles -Base $pbase)) {
        $records.Add((New-SkillRecord -Path $f.FullName -SkillScope 'personal' -PluginName $null -RootPath $pbase))
    }
}
if ($Scope -in @('all','plugin')) {
    $plbase = Join-Path $userHome '.claude/plugins'
    foreach ($f in (Find-SkillFiles -Base $plbase)) {
        $p   = ($f.FullName -replace '\\','/')
        $pm  = [regex]::Match($p, '/plugins/(?:cache/)?([^/]+)/')
        $plg = if ($pm.Success) { $pm.Groups[1].Value } else { 'plugin' }
        $records.Add((New-SkillRecord -Path $f.FullName -SkillScope 'plugin' -PluginName $plg -RootPath $plbase))
    }
}

# ── Overlaps (near-duplicate descriptions by keyword Jaccard) ────────────────────
$overlaps = [System.Collections.Generic.List[object]]::new()

# The same skill is normally visible through several copies at once (the repo working tree, the
# installed plugin cache, the marketplaces clone, worktrees under .claude/worktrees): 273 of the
# 357 findings the audit produced on one real machine paired a skill with ITS OWN copy. So the
# pass works on VARIANTS: records with the same base name and the same description (whitespace
# and case aside) are one variant, and only variants are compared. Nothing is hidden: the copies
# folded into a variant are counted (`aCopies`/`bCopies`, `summary.collapsedCopies`), and two
# copies of one name whose descriptions DIFFER stay visible as a `divergent-copy` pair (a stale copy).
$scopeRank = @{ project = 0; personal = 1; plugin = 2 }
# Most local first: project, personal, plugin; and within a scope the real tree before a copy of it
# under .claude/worktrees. Ties by path, so the choice never depends on directory-enumeration order.
function Get-CopyRank {
    param($Record)
    ([int]$scopeRank[$Record.scope]) * 2 + $(if ($Record.path -match '/\.claude/worktrees/') { 1 } else { 0 })
}
$variantMap = [ordered]@{}
for ($i = 0; $i -lt $records.Count; $i++) {
    $r = $records[$i]
    $fp  = (([string]$r.description) -replace '\s+', ' ').Trim().ToLowerInvariant()
    $key = ([string]$r.name).ToLowerInvariant() + "`n" + $fp
    if (-not $variantMap.Contains($key)) { $variantMap[$key] = [System.Collections.Generic.List[int]]::new() }
    $variantMap[$key].Add($i)
}
$variants = @(foreach ($idxs in $variantMap.Values) {
    $rep = @($idxs | Sort-Object @{ e = { Get-CopyRank $records[$_] } }, @{ e = { $records[$_].path } })[0]
    [pscustomobject]@{
        Rec    = $records[$rep]
        Copies = $idxs.Count
        # Unary comma: a HashSet is enumerable and would otherwise be flattened into its strings.
        Set    = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($records[$rep]._keywords) | Where-Object { $_ }))
    }
})

function Get-Jaccard {
    param($A, $B)
    $x = [System.Collections.Generic.HashSet[string]]::new($A)
    $x.IntersectWith($B)
    $union = $A.Count + $B.Count - $x.Count
    if ($union -gt 0) { [math]::Round($x.Count / $union, 3) } else { 0 }
}
function New-Overlap {
    param($VA, $VB, [string]$Kind, $Jaccard)
    [pscustomobject]@{
        a = $VA.Rec.namespace; b = $VB.Rec.namespace; jaccard = $Jaccard; kind = $Kind
        aPath = $VA.Rec.path; bPath = $VB.Rec.path; aCopies = $VA.Copies; bCopies = $VB.Copies
    }
}

# Different skills: every pair used to pipe both keyword lists through Where-Object / Sort-Object:
# ~100k pairs for a normal plugin cache took ~30 s, the bulk of the whole run (#609). Same Jaccard,
# but on HashSets, and a pair is skipped outright when even a perfect overlap of the smaller set
# could not reach the threshold (J <= min/max size).
for ($i = 0; $i -lt $variants.Count; $i++) {
    $a = $variants[$i].Set
    if ($a.Count -eq 0) { continue }
    for ($j = $i + 1; $j -lt $variants.Count; $j++) {
        # Same name = the same skill (compared below as a stale copy), never a "near-duplicate".
        if ($variants[$i].Rec.name -ieq $variants[$j].Rec.name) { continue }
        $b = $variants[$j].Set
        if ($b.Count -eq 0) { continue }
        $lo = [math]::Min($a.Count, $b.Count); $hi = [math]::Max($a.Count, $b.Count)
        if ([math]::Round($lo / $hi, 3) -lt $OverlapThreshold) { continue }
        $jac = Get-Jaccard $a $b
        if ($jac -ge $OverlapThreshold) { $overlaps.Add((New-Overlap $variants[$i] $variants[$j] 'near-duplicate' $jac)) }
    }
}

# One skill, several descriptions: the primary variant (most local copy) against each other one,
# whatever their overlap. Bounded at (variants - 1) pairs per name however many copies exist.
foreach ($grp in ($variants | Group-Object { ([string]$_.Rec.name).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })) {
    $ordered = @($grp.Group | Sort-Object @{ e = { Get-CopyRank $_.Rec } }, @{ e = { $_.Rec.path } })
    for ($k = 1; $k -lt $ordered.Count; $k++) {
        $overlaps.Add((New-Overlap $ordered[0] $ordered[$k] 'divergent-copy' (Get-Jaccard $ordered[0].Set $ordered[$k].Set)))
    }
}
$collapsedCopies = $records.Count - $variants.Count

# Strip the internal keyword field from the public contract.
$clean = $records | Select-Object -Property * -ExcludeProperty _keywords

$result = [pscustomobject]@{
    summary = [pscustomobject]@{
        total       = $clean.Count
        byScope     = ($clean | Group-Object scope | ForEach-Object { @{ $_.Name = $_.Count } })
        misplaced   = @($clean | Where-Object { $_.misplaced }).Count
        overCap     = @($clean | Where-Object { $_.budget.overCap }).Count
        noTriggers  = @($clean | Where-Object { -not $_.lint.hasTriggers }).Count
        overlaps    = $overlaps.Count
        # Records folded into another record of the same name and description before comparing
        # (total - collapsedCopies = distinct skills the overlap pass looked at).
        collapsedCopies = $collapsedCopies
    }
    skills   = $clean
    overlaps = $overlaps
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
