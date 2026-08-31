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
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

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
        hasTriggers    = [bool]($d -match '(?i)(use when|use to|use for|triggers?[:—-]|when the user|when you)')
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
    param([string]$Base)
    if (-not (Test-Path -LiteralPath $Base)) { return @() }
    Get-ChildItem -LiteralPath $Base -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue |
        Where-Object {
            $p = ($_.FullName -replace '\\','/')
            -not ($ExcludeDirs | Where-Object { $p -match "/$([regex]::Escape($_))/" })
        }
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
for ($i = 0; $i -lt $records.Count; $i++) {
    for ($j = $i + 1; $j -lt $records.Count; $j++) {
        $a = $records[$i]._keywords; $b = $records[$j]._keywords
        if (-not $a -or -not $b -or $a.Count -eq 0 -or $b.Count -eq 0) { continue }
        $inter = @($a | Where-Object { $b -contains $_ }).Count
        $union = (@($a) + @($b) | Sort-Object -Unique).Count
        $jac   = if ($union -gt 0) { [math]::Round($inter / $union, 3) } else { 0 }
        if ($jac -ge $OverlapThreshold) {
            $overlaps.Add([pscustomobject]@{
                a = $records[$i].namespace; b = $records[$j].namespace; jaccard = $jac
            })
        }
    }
}

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
    }
    skills   = $clean
    overlaps = $overlaps
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
