<#  Install-ToolFromCatalog.ps1 — install referenced tools from the unified catalog (#387).

    Resolves items through Get-ToolsCatalog and installs by KIND, never duplicating:
      - skill-clone : delegates to Install-SkillFromRepo.ps1 (clean clone, LICENSE preserved).
      - plugin      : SURFACES its own install command (all-or-nothing) — never auto-run, because a
                      marketplace plugin is global/interactive and cherry-picking one skill is wrong.
      - reference   : a catalogued URL with no installer — reports it and the URL to open.
    An already-installed tool is skipped. -DryRun reports intent without touching anything.

    -Id           install ONE tool by id or name (case-insensitive).
    -DryRun       report what would happen; install nothing.
    -Root/-CatalogDir/-InstalledNames/-InstalledPlugins  passthrough to Get-ToolsCatalog.
    -Dest/-Force  passthrough to the skill installer.
    -InstallSkillWith  installer script path (default Install-SkillFromRepo.ps1) — injected in tests.

    EXAMPLES
      .\Install-ToolFromCatalog.ps1 -Id skill-creator
      .\Install-ToolFromCatalog.ps1 -Id skills-for-fabric   # prints the plugin's install command
#>
[CmdletBinding()]
param(
    [string]$Id,
    [switch]$All,
    [switch]$Yes,
    [switch]$DryRun,
    [string]$Root = (Get-Location).Path,
    [string]$CatalogDir,
    [string[]]$InstalledNames,
    [string[]]$InstalledPlugins,
    [string[]]$InstalledMcpServers,
    [string]$Dest,
    [switch]$Force,
    [string]$InstallSkillWith
)

$ErrorActionPreference = 'Stop'

if (-not $InstallSkillWith) { $InstallSkillWith = Join-Path $PSScriptRoot 'Install-SkillFromRepo.ps1' }
$resolver = Join-Path $PSScriptRoot 'Get-ToolsCatalog.ps1'

# forward only supplied resolver params
$fwd = @{ Root = $Root }
if ($CatalogDir) { $fwd.CatalogDir = $CatalogDir }
if ($PSBoundParameters.ContainsKey('InstalledNames'))      { $fwd.InstalledNames      = $InstalledNames }
if ($PSBoundParameters.ContainsKey('InstalledPlugins'))    { $fwd.InstalledPlugins    = $InstalledPlugins }
if ($PSBoundParameters.ContainsKey('InstalledMcpServers')) { $fwd.InstalledMcpServers = $InstalledMcpServers }

function Install-One($t, [bool]$dry) {
    if (-not $t.installable) {
        Write-Output ("  {0}: reference only (not installable). Open: {1}" -f $t.id, $t.url)
        return [pscustomobject]@{ id=$t.id; action='reference'; installed=$false }
    }
    if ($t.installed) {
        Write-Output ("  {0}: already installed - skipping." -f $t.id)
        return [pscustomobject]@{ id=$t.id; action='skip-installed'; installed=$true }
    }
    if ($t.kind -eq 'plugin') {
        Write-Output ("  {0}: plugin (all-or-nothing) - install it yourself:" -f $t.id)
        Write-Output ("      {0}" -f $t.installMethod)
        return [pscustomobject]@{ id=$t.id; action='surface-plugin'; installed=$false; command=$t.installMethod }
    }
    if ($t.kind -eq 'mcp') {
        Write-Output ("  {0}: MCP server - run this to add it:" -f $t.id)
        Write-Output ("      {0}" -f $t.installMethod)
        return [pscustomobject]@{ id=$t.id; action='surface-mcp'; installed=$false; command=$t.installMethod }
    }
    # skill-clone
    if ($dry) {
        Write-Output ("  {0}: WOULD clone {1}/{2} -> ~/.claude/skills/{3}" -f $t.id, $t.repo, $t.path, $t.name)
        return [pscustomobject]@{ id=$t.id; action='dry-run'; installed=$false }
    }
    $iargs = @{ Repo=$t.repo; Path=$t.path; Name=$t.name }
    if ($t.owner)   { $iargs.Owner   = $t.owner }
    if ($t.license) { $iargs.License = $t.license }
    if ($Dest)      { $iargs.Dest    = $Dest }
    if ($Force)     { $iargs.Force   = $true }
    $res = & $InstallSkillWith @iargs
    Write-Output ("  {0}: installed (skill-clone {1}/{2})." -f $t.id, $t.repo, $t.path)
    return [pscustomobject]@{ id=$t.id; action='install-skill'; installed=$true; result=$res }
}

if ($PSBoundParameters.ContainsKey('Id') -and $Id) {
    $item = @((& $resolver @fwd -Id $Id).items)
    if ($item.Count -eq 0) {
        Write-Output "Tool '$Id' not found in the catalog. Run /tools browse to see valid ids."
        return
    }
    return (Install-One $item[0] ([bool]$DryRun))
}

if ($All) {
    $missing  = @((& $resolver @fwd -MissingOnly).items)
    $skills   = @($missing | Where-Object { $_.kind -eq 'skill-clone' })
    $plugins  = @($missing | Where-Object { $_.kind -eq 'plugin' })
    $mcps     = @($missing | Where-Object { $_.kind -eq 'mcp' })

    if ($missing.Count -eq 0) {
        Write-Output "install --all: nothing to install - every installable tool is already present."
        return [pscustomobject]@{ installed=0; surfaced=0; missing=0 }
    }

    Write-Output ("install --all: {0} missing installable(s) - {1} skill-clone(s) to install, {2} plugin(s) to surface, {3} MCP server(s) to surface." -f $missing.Count, $skills.Count, $plugins.Count, $mcps.Count)
    foreach ($s in $skills)  { Write-Output ("  - {0} (skill-clone {1}/{2})" -f $s.id, $s.repo, $s.path) }
    foreach ($p in $plugins) { Write-Output ("  ~ {0} (plugin): {1}" -f $p.id, $p.installMethod) }
    foreach ($m in $mcps)    { Write-Output ("  ~ {0} (mcp): {1}" -f $m.id, $m.installMethod) }

    # Safe by default: only -Yes actually clones. Without it (or with -DryRun) this is a preview.
    $proceed = $Yes -and -not $DryRun
    if (-not $proceed) {
        Write-Output "(preview) re-run with -Yes to install the skill-clone(s); plugins are surfaced for you to run."
        return [pscustomobject]@{ installed=0; surfaced=$plugins.Count; missing=$missing.Count; previewed=$true }
    }

    $results = foreach ($t in $missing) { Install-One $t $false }
    $done = @($results | Where-Object { $_.action -eq 'install-skill' }).Count
    Write-Output ("install --all: installed {0} skill-clone(s); {1} plugin(s) surfaced; {2} MCP server(s) surfaced." -f $done, $plugins.Count, $mcps.Count)
    return [pscustomobject]@{ installed=$done; surfaced=($plugins.Count + $mcps.Count); missing=$missing.Count }
}

Write-Output "Nothing to do: pass -Id <id> to install one tool, or -All to install every missing installable."
