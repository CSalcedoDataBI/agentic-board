<#  Get-SkillGaps.ps1 — which catalog tools are missing for a profile?

    Reads a curated PROFILE catalog (presets/toolkits/<profile>.json), compares it against
    what is actually installed, and reports installed vs gaps. It NEVER installs anything and
    never duplicates — install is the agentic step the SKILL.md drives. Detection is
    deterministic and differs by install kind:
      - skill-clone : matched by `name` against the installed skill inventory (all scopes).
      - plugin      : matched by `detect` (the marketplace/plugin id as it appears in
                      `claude plugin list`), falling back to `name`.

    -Profile picks the catalog (default 'quality'); -CatalogPath overrides it outright.
    -InstalledNames / -InstalledPlugins override the detected install sets (used by tests;
    they default to the live inventory / `claude plugin list`).

    EXAMPLES
      .\Get-SkillGaps.ps1 -Profile bi
      .\Get-SkillGaps.ps1 -Profile quality -Json
#>
[CmdletBinding()]
param(
    [string]$Profile = 'quality',
    [string]$CatalogPath,
    [string[]]$InstalledNames,
    [string[]]$InstalledPlugins,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $CatalogPath) {
    $CatalogPath = Join-Path $PSScriptRoot '..' 'presets' 'toolkits' "$Profile.json"
}
if (-not (Test-Path $CatalogPath)) { throw "Catalog not found: $CatalogPath (profile '$Profile')" }
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json

if (-not $PSBoundParameters.ContainsKey('InstalledNames')) {
    $engine = Join-Path $PSScriptRoot 'Get-SkillInventory.ps1'
    $InstalledNames = (& $engine -Scope all).skills.name
}
if (-not $PSBoundParameters.ContainsKey('InstalledPlugins')) {
    $pl = Join-Path $PSScriptRoot 'Get-InstalledPlugins.ps1'
    $InstalledPlugins = if (Test-Path $pl) { @(& $pl) } else { @() }
}

$haveSkill  = @{}
foreach ($n in $InstalledNames)   { if ($n) { $haveSkill[$n.ToLower()]  = $true } }
$havePlugin = @{}
foreach ($p in $InstalledPlugins) { if ($p) { $havePlugin[([string]$p).ToLower()] = $true } }

function Test-EntryInstalled($c) {
    $props = $c.PSObject.Properties.Name
    $kind  = if ($props -contains 'kind' -and $c.kind) { $c.kind } else { 'skill-clone' }
    if ($kind -eq 'plugin') {
        $key = if ($props -contains 'detect' -and $c.detect) { $c.detect } else { $c.name }
        return $havePlugin.ContainsKey(([string]$key).ToLower())
    }
    return $haveSkill.ContainsKey(([string]$c.name).ToLower())
}

$installed = [System.Collections.Generic.List[object]]::new()
$gaps      = [System.Collections.Generic.List[object]]::new()
foreach ($c in $catalog) {
    if (Test-EntryInstalled $c) { $installed.Add($c) } else { $gaps.Add($c) }
}

$result = [pscustomobject]@{
    profile   = $Profile
    summary   = [pscustomobject]@{ recommended = @($catalog).Count; installed = $installed.Count; gaps = $gaps.Count }
    installed = $installed
    gaps      = $gaps
}

if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }
