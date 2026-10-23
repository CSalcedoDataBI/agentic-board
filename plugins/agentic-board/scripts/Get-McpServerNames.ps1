<#  Get-McpServerNames.ps1 — the MCP server prefixes the agent really sees on this machine.

    A tool from an MCP server reaches the agent as mcp__<prefix>__<tool>. The prefix is the bare
    server name when the server is configured directly (~/.claude.json, its per-project entry, or the
    project's .mcp.json — what `claude mcp list` reads), and plugin_<plugin>_<server> when the server
    comes from an installed plugin (its .mcp.json, or the mcpServers of its plugin.json).

    The config files are read instead of shelling out to `claude mcp list`: that command health-checks
    every server (seconds each) and does not show the plugin prefix. Disabled plugins
    (enabledPlugins = false in ~/.claude/settings.json) are left out: their tools are not loaded.

    Read-only. Emits one record per prefix: { prefix, server, plugin, source }.

    EXAMPLES
      .\Get-McpServerNames.ps1 -Root .
      .\Get-McpServerNames.ps1 -UserHome C:\fixture\home -Root C:\fixture\repo
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$UserHome
)

$ErrorActionPreference = 'Stop'
if (-not $UserHome) { $UserHome = $env:USERPROFILE; if (-not $UserHome) { $UserHome = $HOME } }
# Resolved against the PowerShell location: [IO.Path]::GetFullPath would use the process CWD, which
# Set-Location does not move, and the two lookups below would disagree on which project this is.
$Root = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Root)
$rootN = ($Root -replace '\\','/').TrimEnd('/')

function Read-Json {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $File -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}
# An .mcp.json is either { "mcpServers": { ... } } or the server map itself. ~/.claude.json and its
# per-project entries hold many other keys, so for them only an mcpServers member counts (-Wrapped).
function Get-ServerMapNames {
    param($Map, [switch]$Wrapped)
    if (-not $Map -or $Map -is [string] -or $Map -is [System.Collections.IList]) { return @() }
    if ($Map.PSObject.Properties['mcpServers']) { $Map = $Map.mcpServers }
    elseif ($Wrapped) { return @() }
    if (-not $Map -or $Map -is [string] -or $Map -is [System.Collections.IList]) { return @() }
    @($Map.PSObject.Properties | ForEach-Object { $_.Name })
}

$out  = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Server {
    param([string]$Server, [string]$Plugin, [string]$Source)
    # Claude Code builds the tool name with every character outside [A-Za-z0-9_-] turned into `_`.
    $s = $Server -replace '[^A-Za-z0-9_-]', '_'
    $p = if ($Plugin) { $Plugin -replace '[^A-Za-z0-9_-]', '_' } else { $null }
    $prefix = if ($p) { "plugin_$($p)_$s" } else { $s }
    if ($seen.Add($prefix)) {
        $out.Add([pscustomobject]@{ prefix = $prefix; server = $s; plugin = $p; source = $Source })
    }
}

# ── Direct servers: user, per-project (local scope), project .mcp.json ───────────────
$cfg = Read-Json (Join-Path $UserHome '.claude.json')
foreach ($n in (Get-ServerMapNames $cfg -Wrapped)) { Add-Server $n $null 'user' }
if ($cfg -and $cfg.projects) {
    foreach ($p in $cfg.projects.PSObject.Properties) {
        $k = ($p.Name -replace '\\','/').TrimEnd('/')
        if ($k -ieq $rootN) { foreach ($n in (Get-ServerMapNames $p.Value -Wrapped)) { Add-Server $n $null 'local' } }
    }
}
foreach ($n in (Get-ServerMapNames (Read-Json (Join-Path $Root '.mcp.json')))) { Add-Server $n $null 'project' }

# ── Plugin servers: every installed, enabled plugin ──────────────────────────────────
# enabledPlugins is merged user < project < local, the precedence Claude Code applies; a plugin set
# to false at the most specific level that names it is not loaded.
$enabled = @{}
foreach ($sf in @((Join-Path $UserHome '.claude/settings.json'), (Join-Path $Root '.claude/settings.json'), (Join-Path $Root '.claude/settings.local.json'))) {
    $st = Read-Json $sf
    if ($st -and $st.enabledPlugins -and $st.enabledPlugins -isnot [string]) {
        foreach ($e in $st.enabledPlugins.PSObject.Properties) { $enabled[$e.Name] = $e.Value }
    }
}
$installed = Read-Json (Join-Path $UserHome '.claude/plugins/installed_plugins.json')
if ($installed -and $installed.plugins) {
    foreach ($entry in $installed.plugins.PSObject.Properties) {
        $key = $entry.Name                                  # <plugin>@<marketplace>
        if ($enabled.ContainsKey($key) -and $enabled[$key] -eq $false) { continue }
        $plugin = ($key -split '@')[0]
        # A project- or local-scope install only loads in its own project.
        $here = @(@($entry.Value) | Where-Object {
            $_ -and $_.installPath -and (
                $_.scope -notin 'project', 'local' -or
                (([string]$_.projectPath -replace '\\','/').TrimEnd('/') -ieq $rootN))
        })
        # Several installs that apply here: the most recently updated wins. ConvertFrom-Json has
        # already turned the ISO timestamp into a DateTime; a string sort of it would be MM/dd/yyyy.
        $inst = $here | Sort-Object { $_.lastUpdated -as [datetime] } -Descending | Select-Object -First 1
        if (-not $inst) { continue }
        $names = @(Get-ServerMapNames (Read-Json (Join-Path $inst.installPath '.mcp.json')))
        $man = Read-Json (Join-Path $inst.installPath '.claude-plugin/plugin.json')
        if ($man -and $man.PSObject.Properties['mcpServers']) {
            # mcpServers inlines the map, or points at one file or a list of files (relative to the plugin root).
            foreach ($ms in @($man.mcpServers)) {
                if ($ms -is [string]) { $ms = Read-Json (Join-Path $inst.installPath $ms) }
                $names += @(Get-ServerMapNames $ms)
            }
        }
        foreach ($n in $names) { Add-Server $n $plugin "plugin:$key" }
    }
}

$out
