<#  Get-McpServerNames.ps1 — the MCP server prefixes the agent really sees on this machine.

    A tool from an MCP server reaches the agent as mcp__<prefix>__<tool>. The prefix is the bare
    server name when the server is configured directly (~/.claude.json, its per-project entry, or the
    project's .mcp.json — what `claude mcp list` reads), and plugin_<plugin>_<server> when the server
    comes from an installed plugin (its .mcp.json, or the mcpServers of its plugin.json).

    The config files are read instead of shelling out to `claude mcp list`: that command health-checks
    every server (seconds each) and does not show the plugin prefix. Config is read from
    CLAUDE_CONFIG_DIR when it is set. What is not loaded is left out: plugins that enabledPlugins does
    not set to true (user < project < local settings), project- or local-scope
    installs of another project, servers switched off in the project (disabledMcpServers), and project
    .mcp.json servers that were rejected or never approved.

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
# Claude Code keeps .claude.json, settings.json and plugins/ under CLAUDE_CONFIG_DIR when it is set, and
# otherwise .claude.json in the home and the rest in ~/.claude. -UserHome (fixtures) always wins.
if (-not $UserHome -and $env:CLAUDE_CONFIG_DIR) {
    $configDir = $env:CLAUDE_CONFIG_DIR; $claudeJson = Join-Path $configDir '.claude.json'
} else {
    if (-not $UserHome) { $UserHome = $env:USERPROFILE; if (-not $UserHome) { $UserHome = $HOME } }
    $configDir = Join-Path $UserHome '.claude'; $claudeJson = Join-Path $UserHome '.claude.json'
}
# Resolved against the PowerShell location: [IO.Path]::GetFullPath would use the process CWD, which
# Set-Location does not move, and the two lookups below would disagree on which project this is.
$Root = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Root)
$rootN = ($Root -replace '\\','/').TrimEnd('/')

# Every file is read -AsHashtable: ~/.claude.json records one project under keys that differ only in
# case (c:/… and C:/…), and a plain ConvertFrom-Json throws on that, which would drop the whole file.
function Read-Json {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $File -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Write-Warning "Get-McpServerNames: cannot read $File - its MCP servers are left out."; $null }
}
function Test-Map { param($Value) $Value -is [System.Collections.IDictionary] }
# An .mcp.json is either { "mcpServers": { ... } } or the server map itself. ~/.claude.json and its
# per-project entries hold many other keys, so for them only an mcpServers member counts (-Wrapped).
function Get-ServerMapNames {
    param($Map, [switch]$Wrapped)
    if (-not (Test-Map $Map)) { return @() }
    if ($Map.Contains('mcpServers')) { $Map = $Map['mcpServers'] }
    elseif ($Wrapped) { return @() }
    if (-not (Test-Map $Map)) { return @() }
    @($Map.Keys)
}
function Get-List { param($Map, [string]$Key) if ((Test-Map $Map) -and $Map.Contains($Key)) { @($Map[$Key] | Where-Object { $_ -is [string] }) } else { @() } }

$cfg = Read-Json $claudeJson
# The project's own entries in ~/.claude.json: every key that names this root, whatever its case or slashes.
$projEntries = @()
if ((Test-Map $cfg) -and (Test-Map $cfg['projects'])) {
    $projEntries = @($cfg['projects'].GetEnumerator() |
        Where-Object { (([string]$_.Key -replace '\\','/').TrimEnd('/')) -ieq $rootN -and (Test-Map $_.Value) } |
        ForEach-Object { $_.Value })
}
# Settings merged user < project < local, the precedence Claude Code applies.
$settingsFiles = @((Join-Path $configDir 'settings.json'), (Join-Path $Root '.claude/settings.json'), (Join-Path $Root '.claude/settings.local.json'))
$settings = @($settingsFiles | ForEach-Object { Read-Json $_ } | Where-Object { Test-Map $_ })

# Servers switched off in this project (/mcp disable): bare names, and plugin:<plugin>:<server> for plugin ones.
$disabled = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $projEntries) { foreach ($n in (Get-List $e 'disabledMcpServers')) { [void]$disabled.Add($n) } }

$out  = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Server {
    param([string]$Server, [string]$Plugin, [string]$Source)
    $id = if ($Plugin) { "plugin:$($Plugin):$Server" } else { $Server }
    if ($disabled.Contains($id)) { return }
    # Claude Code builds the tool name with every character outside [A-Za-z0-9_-] turned into `_`.
    $s = $Server -replace '[^A-Za-z0-9_-]', '_'
    $p = if ($Plugin) { $Plugin -replace '[^A-Za-z0-9_-]', '_' } else { $null }
    $prefix = if ($p) { "plugin_$($p)_$s" } else { $s }
    if ($seen.Add($prefix)) {
        $out.Add([pscustomobject]@{ prefix = $prefix; server = $s; plugin = $p; source = $Source })
    }
}

# ── Direct servers: user, per-project (local scope), project .mcp.json ───────────────
foreach ($n in (Get-ServerMapNames $cfg -Wrapped)) { Add-Server $n $null 'user' }
foreach ($e in $projEntries) { foreach ($n in (Get-ServerMapNames $e -Wrapped)) { Add-Server $n $null 'local' } }
# A project .mcp.json server loads only once approved (enableAllProjectMcpServers or listed in
# enabledMcpjsonServers) and not rejected (disabledMcpjsonServers).
$approveAll = $false
$approved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rejected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($src in @($projEntries) + @($settings)) {
    # The most specific level that sets it decides (user < project < local), like enabledPlugins.
    if ((Test-Map $src) -and $src.Contains('enableAllProjectMcpServers')) { $approveAll = $src['enableAllProjectMcpServers'] -eq $true }
    foreach ($n in (Get-List $src 'enabledMcpjsonServers'))  { [void]$approved.Add($n) }
    foreach ($n in (Get-List $src 'disabledMcpjsonServers')) { [void]$rejected.Add($n) }
}
foreach ($n in (Get-ServerMapNames (Read-Json (Join-Path $Root '.mcp.json')))) {
    if (-not $rejected.Contains($n) -and ($approveAll -or $approved.Contains($n))) { Add-Server $n $null 'project' }
}

# ── Plugin servers: every installed, enabled plugin ──────────────────────────────────
# Claude Code loads the plugins enabledPlugins sets to true; the most specific settings level that names
# a plugin decides. A plugin installed but named nowhere is not counted: no prefix is guessed.
$enabled = @{}
foreach ($st in $settings) {
    if (Test-Map $st['enabledPlugins']) { foreach ($e in $st['enabledPlugins'].GetEnumerator()) { $enabled[$e.Key] = $e.Value } }
}
$installed = Read-Json (Join-Path $configDir 'plugins/installed_plugins.json')
if ((Test-Map $installed) -and (Test-Map $installed['plugins'])) {
    foreach ($entry in $installed['plugins'].GetEnumerator()) {
        $key = [string]$entry.Key                           # <plugin>@<marketplace>
        if (-not ($enabled.ContainsKey($key) -and $enabled[$key] -eq $true)) { continue }
        $plugin = ($key -split '@')[0]
        # A project- or local-scope install only loads in its own project.
        $here = @(@($entry.Value) | Where-Object {
            (Test-Map $_) -and $_['installPath'] -and (
                $_['scope'] -notin 'project', 'local' -or
                (([string]$_['projectPath'] -replace '\\','/').TrimEnd('/') -ieq $rootN))
        })
        # Several installs that apply here: the most recently updated wins. ConvertFrom-Json has
        # already turned the ISO timestamp into a DateTime; a string sort of it would be MM/dd/yyyy.
        $inst = $here | Sort-Object { $_['lastUpdated'] -as [datetime] } -Descending | Select-Object -First 1
        if (-not $inst) { continue }
        # One stale entry (an install path on a drive that is gone) costs that plugin only.
        try {
            $base = [string]$inst['installPath']
            $names = @(Get-ServerMapNames (Read-Json ([IO.Path]::Combine($base, '.mcp.json'))))
            $man = Read-Json ([IO.Path]::Combine($base, '.claude-plugin', 'plugin.json'))
            if ((Test-Map $man) -and $man.Contains('mcpServers')) {
                # mcpServers inlines the map, or points at one file or a list of files (relative to the plugin root).
                foreach ($ms in @($man['mcpServers'])) {
                    if ($ms -is [string]) { $ms = Read-Json ([IO.Path]::Combine($base, $ms)) }
                    $names += @(Get-ServerMapNames $ms)
                }
            }
            foreach ($n in $names) { Add-Server $n $plugin "plugin:$key" }
        } catch {
            Write-Warning "Get-McpServerNames: cannot read plugin $key ($($_.Exception.Message)) - its MCP servers are left out."
        }
    }
}

$out
