<#  Get-ToolsCatalog.ps1 — the unified referenced-tools catalog resolver (#385).

    Merges the two sources that describe the external tools a project references and can install:
      - the knowledge registry  (knowledge/registry.json)   — the *references* (what exists / why)
      - the toolkit presets      (presets/toolkits/*.json)    — the *installers* (what can be installed)
    into ONE de-duplicated item model. Installed-detection reuses the Get-SkillGaps rules
    (skill-clone matched by `name`, plugin matched by `detect` falling back to `name`).

    It NEVER installs anything — install is the agentic step Install-ToolFromCatalog.ps1 / the
    tools-catalog SKILL drive. This script is deterministic and side-effect free.

    Item model (each row):
      id            stable id — preset `name` for installables, registry `id` (kn_xxx) otherwise
      name          human title
      domain        registry domain, else the preset's toolkit file stem
      kind          registry `type` (url/repo/…) OR install kind (plugin / skill-clone)
      url           canonical URL
      installable   $true when a preset carries an install method
      installed     $true when detected in the installed inventory (installables only)
      source        'registry' | 'preset' | 'both'
      note          registry note, else the preset purpose
      installMethod plugin: its install command; skill-clone: 'skill-clone'; else $null
      repo/path/detect  installer coordinates (null for registry-only refs)

    -Root         repo root that holds knowledge/registry.json (default: cwd)
    -CatalogDir   presets/toolkits dir (default: alongside this script)
    -MissingOnly  keep only installable tools that are not installed (feeds install --all)
    -Id           return only the item whose id OR name matches (case-insensitive)
    -InstalledNames / -InstalledPlugins  override the detected install sets (tests); default = live
    -Json         emit JSON

    EXAMPLES
      .\Get-ToolsCatalog.ps1
      .\Get-ToolsCatalog.ps1 -MissingOnly -Json
      .\Get-ToolsCatalog.ps1 -Id skills-for-fabric
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$CatalogDir,
    [switch]$MissingOnly,
    [string]$Id,
    [string[]]$InstalledNames,
    [string[]]$InstalledPlugins,
    [string[]]$InstalledMcpServers,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $CatalogDir) { $CatalogDir = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' }

# --- installed inventory (same sources as Get-SkillGaps) -----------------------
if (-not $PSBoundParameters.ContainsKey('InstalledNames')) {
    $engine = Join-Path $PSScriptRoot 'Get-SkillInventory.ps1'
    $InstalledNames = if (Test-Path $engine) { (& $engine -Scope all).skills.name } else { @() }
}
if (-not $PSBoundParameters.ContainsKey('InstalledPlugins')) {
    $pl = Join-Path $PSScriptRoot 'Get-InstalledPlugins.ps1'
    $InstalledPlugins = if (Test-Path $pl) { @(& $pl) } else { @() }
}
if (-not $PSBoundParameters.ContainsKey('InstalledMcpServers')) {
    $ms = Join-Path $PSScriptRoot 'Get-InstalledMcpServers.ps1'
    $InstalledMcpServers = if (Test-Path $ms) { @(& $ms) } else { @() }
}
$haveSkill = @{}; foreach ($n in $InstalledNames)   { if ($n) { $haveSkill[([string]$n).ToLower()]  = $true } }
$havePlugin = @{}; foreach ($p in $InstalledPlugins) { if ($p) { $havePlugin[([string]$p).ToLower()] = $true } }
$haveMcp    = @{}; foreach ($m in $InstalledMcpServers) { if ($m) { $haveMcp[([string]$m).ToLower()] = $true } }

function Test-PresetInstalled($e) {
    if ($e.kind -eq 'plugin') {
        $key = if ($e.PSObject.Properties.Name -contains 'detect' -and $e.detect) { $e.detect } else { $e.name }
        return $havePlugin.ContainsKey(([string]$key).ToLower())
    }
    if ($e.kind -eq 'mcp') {
        $key = if ($e.PSObject.Properties.Name -contains 'detect' -and $e.detect) { $e.detect } else { $e.name }
        return $haveMcp.ContainsKey(([string]$key).ToLower())
    }
    return $haveSkill.ContainsKey(([string]$e.name).ToLower())
}

function Get-NormUrl($u) {
    if ([string]::IsNullOrWhiteSpace([string]$u)) { return $null }
    $s = ([string]$u).Trim().ToLower() -replace '^https?://', ''
    return $s.TrimEnd('/')
}

# --- source 1: the knowledge registry (references) -----------------------------
. (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')
$regPath = Resolve-KnowledgeRegistryPath -Root $Root
$refs = @()
if (Test-Path -LiteralPath $regPath) { $refs = @((Read-KnowledgeRegistry -Path $regPath).references) }

$order = [System.Collections.Generic.List[string]]::new()
$map   = @{}
function Add-Key([string]$key, $item) { if (-not $map.ContainsKey($key)) { $order.Add($key) }; $map[$key] = $item }

# --- source 2 FIRST: the toolkit presets (installers) --------------------------
# Each preset is its OWN item, keyed by a unique identity — NOT by homepage, because several
# skills can live in one monorepo (same homepage) yet be distinct tools (skill-improver +
# second-opinion both sit in trailofbits/skills). We index homepage → preset keys only to merge
# a registry ref when it maps to EXACTLY ONE preset (an unambiguous whole-tool match).
$homeIdx = @{}
if (Test-Path -LiteralPath $CatalogDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $CatalogDir -Filter '*.json' | Sort-Object Name)) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        foreach ($e in @(Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json)) {
            $installed = Test-PresetInstalled $e
            $method = if ($e.kind -in 'plugin','mcp' -and $e.install) { $e.install } else { $e.kind }
            $pkey = if ($e.kind -in 'plugin','mcp') { "$($e.kind):$(([string]($(if ($e.detect) { $e.detect } else { $e.name }))).ToLower())" }
                    elseif ($e.repo -and $e.path) { "skill:$((([string]$e.repo)+'#'+([string]$e.path)).ToLower())" }
                    else { "name:$(([string]$e.name).ToLower())" }
            Add-Key $pkey ([pscustomobject]@{
                id=$e.name; name=$e.name; domain=$stem; kind=$e.kind; url=$e.homepage
                installable=$true; installed=$installed; source='preset'; note=$e.purpose
                installMethod=$method; repo=$e.repo; path=$e.path; detect=$e.detect; refId=$null
                owner=$e.owner; license=$e.license
            })
            $h = Get-NormUrl $e.homepage
            if ($h) { if (-not $homeIdx.ContainsKey($h)) { $homeIdx[$h] = [System.Collections.Generic.List[string]]::new() }; $homeIdx[$h].Add($pkey) }
        }
    }
}

# --- merge registry refs: into a preset when the URL is unambiguous, else add as a reference ----
foreach ($r in $refs) {
    $u = Get-NormUrl $r.ref
    if ($u -and $homeIdx.ContainsKey($u) -and $homeIdx[$u].Count -eq 1) {
        $x = $map[$homeIdx[$u][0]]              # exactly one preset shares this URL → same tool
        $x.source = 'both'; $x.refId = $r.id; $x.domain = $r.domain
        if ([string]::IsNullOrWhiteSpace([string]$x.note)) { $x.note = $r.note }
    } else {
        $rkey = if ($u) { "ref:$u" } else { "refname:$(([string]$r.title).ToLower())" }
        Add-Key $rkey ([pscustomobject]@{
            id=$r.id; name=$r.title; domain=$r.domain; kind=$r.type; url=$r.ref
            installable=$false; installed=$false; source='registry'; note=$r.note
            installMethod=$null; repo=$null; path=$null; detect=$null; refId=$null
            owner=$null; license=$null
        })
    }
}

$items = [System.Collections.Generic.List[object]]::new()
foreach ($k in $order) { $items.Add($map[$k]) }

# --- filters -------------------------------------------------------------------
$out = @($items)
if ($MissingOnly) { $out = @($out | Where-Object { $_.installable -and -not $_.installed }) }
if ($PSBoundParameters.ContainsKey('Id') -and $Id) {
    $needle = $Id.ToLower()
    $out = @($out | Where-Object { ([string]$_.id).ToLower() -eq $needle -or ([string]$_.name).ToLower() -eq $needle })
}

$result = [pscustomobject]@{
    items   = $out
    summary = [pscustomobject]@{
        total       = @($out).Count
        installable = @($out | Where-Object installable).Count
        installed   = @($out | Where-Object installed).Count
    }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
