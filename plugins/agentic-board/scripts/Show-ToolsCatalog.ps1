<#  Show-ToolsCatalog.ps1 — browse + research view over Get-ToolsCatalog (#386).

    The read-only presentation layer of the /tools catalog. With no -Id it BROWSES: every
    referenced tool grouped by domain, each row carrying its kind, installed-state and URL — so
    the whole surface (references + installers) is visible from one list. With -Id it RESEARCHES
    one tool: name, source, URL and note, so the user reads the reference before deciding to install.

    It never installs and needs no token — it only renders what Get-ToolsCatalog resolves. The
    -Root / -CatalogDir / -InstalledNames / -InstalledPlugins pass straight through to the resolver
    (the last two let tests pin the installed inventory).

    EXAMPLES
      .\Show-ToolsCatalog.ps1                    # browse everything, grouped by domain
      .\Show-ToolsCatalog.ps1 -Id skills-for-fabric   # research one tool
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$CatalogDir,
    [string]$Id,
    [string[]]$InstalledNames,
    [string[]]$InstalledPlugins
)

$ErrorActionPreference = 'Stop'

# forward only the params the resolver understands (and only when explicitly supplied)
$fwd = @{ Root = $Root }
if ($CatalogDir) { $fwd.CatalogDir = $CatalogDir }
if ($PSBoundParameters.ContainsKey('InstalledNames'))   { $fwd.InstalledNames   = $InstalledNames }
if ($PSBoundParameters.ContainsKey('InstalledPlugins')) { $fwd.InstalledPlugins = $InstalledPlugins }

$resolver = Join-Path $PSScriptRoot 'Get-ToolsCatalog.ps1'

function Get-State($item) {
    if (-not $item.installable) { return 'reference' }
    if ($item.installed)        { return 'installed' }
    return 'available'
}

# --- research one tool ---------------------------------------------------------
if ($PSBoundParameters.ContainsKey('Id') -and $Id) {
    $one = (& $resolver @fwd -Id $Id).items
    if (-not $one -or @($one).Count -eq 0) {
        Write-Output "Tool '$Id' not found in the catalog. Run /tools browse to see valid ids."
        return
    }
    $t = @($one)[0]
    Write-Output $t.name
    Write-Output ("  id          : {0}" -f $t.id)
    Write-Output ("  source      : {0}" -f $t.source)
    Write-Output ("  domain      : {0}" -f $t.domain)
    Write-Output ("  kind        : {0}" -f $t.kind)
    Write-Output ("  url         : {0}" -f $t.url)
    Write-Output ("  installable : {0}" -f $t.installable)
    Write-Output ("  installed   : {0}" -f $t.installed)
    if ($t.installMethod) { Write-Output ("  install     : {0}" -f $t.installMethod) }
    if ($t.note)          { Write-Output ("  note        : {0}" -f $t.note) }
    return
}

# --- browse everything, grouped by domain --------------------------------------
$cat = & $resolver @fwd
$items = @($cat.items)

Write-Output ("Referenced tools: {0} total — {1} installable ({2} installed)." -f `
    $cat.summary.total, $cat.summary.installable, $cat.summary.installed)
Write-Output ''

foreach ($g in ($items | Group-Object domain | Sort-Object Name)) {
    Write-Output ("## {0}" -f $g.Name)
    foreach ($t in ($g.Group | Sort-Object @{e={-[int][bool]$_.installable}}, id)) {
        $state = Get-State $t
        Write-Output ("  [{0,-9}] {1}  ({2})  {3}" -f $state, $t.id, $t.kind, $t.url)
    }
    Write-Output ''
}

Write-Output 'research <id> to read a tool before installing · install <id> · install --all'
