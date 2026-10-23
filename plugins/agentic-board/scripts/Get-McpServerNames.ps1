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

function Read-Json {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $File -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}
# An .mcp.json is either { "mcpServers": { ... } } or the server map itself. ~/.claude.json and its
# per-project entries hold many other keys, so for them only an mcpServers member counts (-Wrapped).
function Get-ServerMapNames {
    param($Map, [switch]$Wrapped)
    if (-not $Map -or $Map -is [string]) { return @() }
    if ($Map.PSObject.Properties['mcpServers']) { $Map = $Map.mcpServers }
    elseif ($Wrapped) { return @() }
    if (-not $Map -or $Map -is [string]) { return @() }
    @($Map.PSObject.Properties | ForEach-Object { $_.Name })
}

$out  = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Server {
    param([string]$Server, [string]$Plugin, [string]$Source)
    $prefix = if ($Plugin) { "plugin_$($Plugin)_$Server" } else { $Server }
    if ($seen.Add($prefix)) {
        $out.Add([pscustomobject]@{ prefix = $prefix; server = $Server; plugin = $Plugin; source = $Source })
    }
}

# ── Direct servers: user, per-project (local scope), project .mcp.json ───────────────
$cfg = Read-Json (Join-Path $UserHome '.claude.json')
foreach ($n in (Get-ServerMapNames $cfg -Wrapped)) { Add-Server $n $null 'user' }
if ($cfg -and $cfg.projects) {
    $rootN = ([System.IO.Path]::GetFullPath($Root) -replace '\\','/').TrimEnd('/')
    foreach ($p in $cfg.projects.PSObject.Properties) {
        $k = ($p.Name -replace '\\','/').TrimEnd('/')
        if ($k -ieq $rootN) { foreach ($n in (Get-ServerMapNames $p.Value -Wrapped)) { Add-Server $n $null 'local' } }
    }
}
foreach ($n in (Get-ServerMapNames (Read-Json (Join-Path $Root '.mcp.json')))) { Add-Server $n $null 'project' }

# ── Plugin servers: every installed, enabled plugin ──────────────────────────────────
$settings = Read-Json (Join-Path $UserHome '.claude/settings.json')
$installed = Read-Json (Join-Path $UserHome '.claude/plugins/installed_plugins.json')
if ($installed -and $installed.plugins) {
    foreach ($entry in $installed.plugins.PSObject.Properties) {
        $key = $entry.Name                                  # <plugin>@<marketplace>
        if ($settings -and $settings.enabledPlugins -and $settings.enabledPlugins.PSObject.Properties[$key] -and
            $settings.enabledPlugins.$key -eq $false) { continue }
        $plugin = ($key -split '@')[0]
        # Several installs of one plugin (user + project scope): the most recently updated wins.
        $inst = @($entry.Value) | Sort-Object { [string]$_.lastUpdated } -Descending | Select-Object -First 1
        if (-not $inst -or -not $inst.installPath) { continue }
        $names = @(Get-ServerMapNames (Read-Json (Join-Path $inst.installPath '.mcp.json')))
        $man = Read-Json (Join-Path $inst.installPath '.claude-plugin/plugin.json')
        if ($man -and $man.PSObject.Properties['mcpServers']) {
            $ms = $man.mcpServers
            # mcpServers may point at a file (relative to the plugin root) instead of inlining the map.
            if ($ms -is [string]) { $ms = Read-Json (Join-Path $inst.installPath $ms) }
            $names += @(Get-ServerMapNames $ms)
        }
        foreach ($n in $names) { Add-Server $n $plugin "plugin:$key" }
    }
}

$out
