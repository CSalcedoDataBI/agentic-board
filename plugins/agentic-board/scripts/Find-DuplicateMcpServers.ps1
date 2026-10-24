<#  Find-DuplicateMcpServers.ps1 - find MCP servers that two plugins register under the same name, and
    (only on confirmation) disable the redundant one in every known project (#757).

    Two plugins can bundle the same MCP server under the same short name - one as a hosted HTTP endpoint,
    another as a local stdio process. Both connect, the session sees two overlapping tool sets, routing
    becomes ambiguous and every request pays the extra tool schemas. Claude Code names each one
    `plugin:<plugin>:<server>`, and listing that id in `projects[<path>].disabledMcpServers` of the user
    config (~/.claude.json) turns it off for that project while the other plugin keeps working.

    What it does:
      plan (default)  reads every installed plugin build (.mcp.json, mcpServers in plugin.json), lists the
                      servers whose short name repeats across plugins with the transport of each, picks
                      which one to keep, and lists every known project that does not disable the others
                      yet. Writes NOTHING. Prints a plan id.
      -Execute        applies exactly that plan: -PlanId must be the id the plan printed, so what is
                      written is what the user saw. The config is backed up first, written atomically,
                      and read back to verify. Nothing outside `disabledMcpServers` is changed.

    Which one is kept: -Keep <plugin | plugin:<plugin>:<server>> decides. Otherwise the hosted one
    (http/sse) is recommended when exactly one is hosted, or the local one with -PreferLocal (when the
    work needs desktop or project files). With no clear choice the group is listed and left alone.

    Honest limits: the setting is PER PROJECT - a project opened for the first time later does not
    inherit it (run this again: it lists the projects that lack it). A running session keeps its servers
    until it restarts, and the app may rewrite the config while it runs, so check `claude mcp list` after.

    -ClaudeHome / -ConfigPath / -BackupDir are path roots so tests use fixtures, never the real files.
    Dot-source guard: set $env:ABIOS_DUPMCP_DOTSOURCE=1 to load the functions without running.  #>
[CmdletBinding()]
param(
    [string]$ClaudeHome,
    [string]$ConfigPath,
    [string[]]$Keep = @(),
    [switch]$PreferLocal,
    [switch]$Execute,
    [string]$PlanId = '',
    [string]$BackupDir,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'PluginState.ps1')

# ---------------------------------------------------------------------------- what each plugin registers

# The user config file: explicit path, else <CLAUDE_CONFIG_DIR>/.claude.json, else ~/.claude.json.
function Get-ClaudeConfigPath {
    param([string]$ConfigPath)
    if ($ConfigPath) { return $ConfigPath }
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json') }
    return (Join-Path $HOME '.claude.json')
}

# hosted | local | unknown, from one server definition.
function Get-McpTransportKind($Def) {
    $type = "$($Def.type)".ToLowerInvariant()
    if ($type -in 'http', 'sse', 'streamable-http', 'ws') { return [pscustomobject]@{ Transport = $type; Kind = 'hosted' } }
    if ($type -eq 'stdio') { return [pscustomobject]@{ Transport = 'stdio'; Kind = 'local' } }
    if ($Def.command) { return [pscustomobject]@{ Transport = 'stdio'; Kind = 'local' } }
    if ($Def.url) { return [pscustomobject]@{ Transport = 'http'; Kind = 'hosted' } }
    return [pscustomobject]@{ Transport = $(if ($type) { $type } else { '?' }); Kind = 'unknown' }
}

# The servers one plugin build declares: .mcp.json at its root ({"mcpServers":{...}} or the bare map)
# and mcpServers in .claude-plugin/plugin.json (a map, or a path to a JSON file inside the build).
#   @{ Server; Transport; Kind }
function Get-PluginMcpServers {
    param([string]$Dir)
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $maps = [System.Collections.Generic.List[object]]::new()
    $mcp = Read-JsonFileSafe (Join-Path $Dir '.mcp.json')
    if ($mcp.Ok) { $maps.Add($(if ($null -ne $mcp.Data.mcpServers) { $mcp.Data.mcpServers } else { $mcp.Data })) }
    $pj = Read-JsonFileSafe (Join-Path (Join-Path $Dir '.claude-plugin') 'plugin.json')
    if ($pj.Ok -and $null -ne $pj.Data.mcpServers) {
        $srv = $pj.Data.mcpServers
        if ($srv -is [string]) {
            $f = Join-Path $Dir ($srv -replace '^\./', '')
            if (Test-PathStrictlyInside -Child $f -Parent $Dir) {
                $r = Read-JsonFileSafe $f
                if ($r.Ok) { $maps.Add($(if ($null -ne $r.Data.mcpServers) { $r.Data.mcpServers } else { $r.Data })) }
            }
        } else { $maps.Add($srv) }
    }
    $seen = @{}
    foreach ($m in $maps) {
        if ($null -eq $m -or $m -isnot [pscustomobject]) { continue }
        foreach ($p in $m.PSObject.Properties) {
            if ($seen.ContainsKey($p.Name) -or $p.Value -isnot [pscustomobject]) { continue }
            $seen[$p.Name] = $true
            $k = Get-McpTransportKind $p.Value
            $out.Add([pscustomobject]@{ Server = $p.Name; Transport = $k.Transport; Kind = $k.Kind })
        }
    }
    return @($out)
}

# Plugins the user settings turn off (enabledPlugins["<plugin>@<marketplace>"] = false). Such a plugin
# loads nowhere, so it is no duplicate and must never be the one kept.
function Get-DisabledPluginKeys {
    param([string]$ClaudeHome)
    $r = Read-JsonFileSafe (Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'settings.json')
    if (-not $r.Ok -or $null -eq $r.Data.enabledPlugins) { return @() }
    return @($r.Data.enabledPlugins.PSObject.Properties | Where-Object { $_.Value -eq $false } | ForEach-Object { $_.Name })
}

# Every MCP server every plugin installed at USER scope registers, one row per (plugin, server). Only
# user scope loads in every project, and the disable is written to every project: a plugin installed for
# one project only (or turned off in the user settings) is skipped, so the copy kept is never missing
# from a project where the other one gets disabled.
#   { Ok; Reason; Items = @{ Id; Plugin; Marketplace; Server; Transport; Kind } }
function Get-PluginMcpRegistrations {
    param([string]$ClaudeHome)
    $inst = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
    if (-not $inst.Ok) { return [pscustomobject]@{ Ok = $false; Reason = $inst.Reason; Items = @() } }
    $off = @(Get-DisabledPluginKeys -ClaudeHome $ClaudeHome)
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($e in @($inst.Entries | Where-Object { $_.Scope -eq 'user' -and $off -notcontains $_.Key })) {
        if ($seen.ContainsKey($e.Key)) { continue }
        $seen[$e.Key] = $true
        foreach ($s in @(Get-PluginMcpServers -Dir $e.InstallPath)) {
            $rows.Add([pscustomobject]@{
                Id = "plugin:$($e.Plugin):$($s.Server)"; Plugin = $e.Plugin; Marketplace = $e.Marketplace
                Server = $s.Server; Transport = $s.Transport; Kind = $s.Kind
            })
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Items = @($rows) }
}

# ---------------------------------------------------------------------------- the decision (pure)

# Servers whose short name repeats across plugins, each with what to keep and what to disable.
#   @{ Server; Members (rows); Keep (row or $null); Disable (rows); Reason }
function Get-DuplicateMcpGroups {
    param([object[]]$Registrations, [string[]]$Keep = @(), [switch]$PreferLocal)
    $wanted = @($Keep | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($Registrations | Group-Object { $_.Server.ToLowerInvariant() } | Sort-Object Name)) {
        $members = @($g.Group | Sort-Object Plugin)
        if (@($members | ForEach-Object { $_.Plugin } | Select-Object -Unique).Count -lt 2) { continue }
        $pick = $null; $why = ''
        $byUser = @($members | Where-Object { $wanted -contains $_.Plugin.ToLowerInvariant() -or $wanted -contains $_.Id.ToLowerInvariant() })
        if ($byUser.Count -eq 1) {
            $pick = $byUser[0]; $why = 'you chose it'
        } elseif ($byUser.Count -gt 1) {
            $why = 'you chose more than one of them; keep exactly one'
        } else {
            $prefer = if ($PreferLocal) { 'local' } else { 'hosted' }
            $cands = @($members | Where-Object { $_.Kind -eq $prefer })
            if ($cands.Count -eq 1) {
                $pick = $cands[0]
                $why = if ($PreferLocal) { 'the local one (the work needs desktop or project files)' } else { 'the hosted one (no local process; use -PreferLocal when the work needs desktop or project files)' }
            } elseif ($cands.Count -gt 1) {
                $why = "more than one is $prefer; choose with -Keep <plugin>"
            } else {
                $why = "none is $prefer; choose with -Keep <plugin>"
            }
        }
        $disable = if ($pick) { @($members | Where-Object { $_.Id -ne $pick.Id }) } else { @() }
        $groups.Add([pscustomobject]@{ Server = $members[0].Server; Members = $members; Keep = $pick; Disable = $disable; Reason = $why })
    }
    return @($groups)
}

# ---------------------------------------------------------------------------- the user config

# The config as a JSON tree that round-trips every value it does not touch.
#   { Ok; Reason; Node; Path }
function Read-ClaudeConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Reason = 'missing'; Node = $null; Path = $Path } }
    try {
        $node = [System.Text.Json.Nodes.JsonNode]::Parse([System.IO.File]::ReadAllText($Path))
    } catch { return [pscustomobject]@{ Ok = $false; Reason = 'unreadable'; Node = $null; Path = $Path } }
    if ($null -eq $node -or $node -isnot [System.Text.Json.Nodes.JsonObject]) { return [pscustomobject]@{ Ok = $false; Reason = 'not a JSON object'; Node = $null; Path = $Path } }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Node = $node; Path = $Path }
}

function Get-JsonStringList($Node) {
    if ($Node -isnot [System.Text.Json.Nodes.JsonArray]) { return @() }
    # ToString() of a string JsonValue is the raw text (no quotes); other kinds are skipped.
    return @(foreach ($x in $Node) { if ($x -is [System.Text.Json.Nodes.JsonValue] -and "$($x.GetValueKind())" -eq 'String') { $x.ToString() } })
}

# Every known project and what each one still lacks.
#   { Projects; Missing = @{ Project; Id }; KeptButDisabled = @{ Project; Id }; PlanId }
function Get-McpDisablePlan {
    param($Config, [object[]]$Groups)
    $missing = [System.Collections.Generic.List[object]]::new()
    $keptOff = [System.Collections.Generic.List[object]]::new()
    $projects = @()
    $pr = $Config.Node['projects']
    if ($pr -is [System.Text.Json.Nodes.JsonObject]) {
        foreach ($kv in $pr) {
            if ($kv.Value -isnot [System.Text.Json.Nodes.JsonObject]) { continue }
            $projects += $kv.Key
            $off = @(Get-JsonStringList $kv.Value['disabledMcpServers'])
            foreach ($g in $Groups) {
                # A project that already turned the KEPT copy off has no duplicate: disabling the other
                # one there would leave it without the server at all. Report it, change nothing.
                if ($g.Keep -and $off -contains $g.Keep.Id) { $keptOff.Add([pscustomobject]@{ Project = $kv.Key; Id = $g.Keep.Id }); continue }
                foreach ($d in $g.Disable) { if ($off -notcontains $d.Id) { $missing.Add([pscustomobject]@{ Project = $kv.Key; Id = $d.Id }) } }
            }
        }
    }
    # The plan id fingerprints exactly what would be written, so -Execute writes what the user saw.
    $text = (@($missing | ForEach-Object { "$($_.Project)`t$($_.Id)" } | Sort-Object) -join "`n")
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    $planId = ([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    return [pscustomobject]@{ Projects = $projects; Missing = @($missing); KeptButDisabled = @($keptOff); PlanId = $planId }
}

# Add the missing ids, back up first, write atomically, read back to verify. Touches nothing but
# projects[<path>].disabledMcpServers. Refuses when the file no longer yields the plan the user confirmed.
#   { Ok; Reason; Backup; Added; Verified }
function Invoke-McpDisable {
    param([Parameter(Mandatory)][string]$ConfigPath, [object[]]$Groups, [Parameter(Mandatory)][string]$PlanId, [Parameter(Mandatory)][string]$BackupDir)
    $no = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why; Backup = ''; Added = 0; Verified = $false } }
    # A link (dotfile managers) would be replaced by a plain file and the real target left stale: refuse.
    $item = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    if ($item -and (Test-IsLinkItem $item)) { return (& $no 'the config is a link; edit its target by hand or point -ConfigPath at it') }
    $cfg = Read-ClaudeConfig -Path $ConfigPath
    if (-not $cfg.Ok) { return (& $no "could not read the config ($($cfg.Reason))") }
    $plan = Get-McpDisablePlan -Config $cfg -Groups $Groups
    if ($plan.PlanId -ne $PlanId) { return (& $no "the config changed since the plan you confirmed (plan $PlanId, now $($plan.PlanId)); run the plan again") }
    if ($plan.Missing.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Reason = 'nothing to change'; Backup = ''; Added = 0; Verified = $true } }

    [void][System.IO.Directory]::CreateDirectory($BackupDir)
    $backup = Join-Path $BackupDir ('claude.json.{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    [System.IO.File]::Copy($ConfigPath, $backup, $false)

    $pr = $cfg.Node['projects']
    foreach ($m in $plan.Missing) {
        $proj = $pr[$m.Project]
        $arr = $proj['disabledMcpServers']
        if ($arr -isnot [System.Text.Json.Nodes.JsonArray]) {
            $arr = [System.Text.Json.Nodes.JsonArray]::new()
            $proj['disabledMcpServers'] = $arr
        }
        $arr.Add([System.Text.Json.Nodes.JsonNode]::Parse(($m.Id | ConvertTo-Json -Compress)))
    }
    $opts = [System.Text.Json.JsonSerializerOptions]::new()
    $opts.WriteIndented = $true
    $opts.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $tmp = "$ConfigPath.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $cfg.Node.ToJsonString($opts), [System.Text.UTF8Encoding]::new($false))
        # The config can hold API keys: on Unix keep its mode (often 0600) instead of the umask default.
        if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($tmp, [System.IO.File]::GetUnixFileMode($ConfigPath)) }
        [System.IO.File]::Move($tmp, $ConfigPath, $true)
    } catch {
        try { [System.IO.File]::Delete($tmp) } catch { }
        return [pscustomobject]@{ Ok = $false; Reason = "could not write the config: $($_.Exception.Message)"; Backup = $backup; Added = 0; Verified = $false }
    }
    $after = Read-ClaudeConfig -Path $ConfigPath
    $left = if ($after.Ok) { @((Get-McpDisablePlan -Config $after -Groups $Groups).Missing).Count } else { -1 }
    return [pscustomobject]@{ Ok = ($left -eq 0); Reason = $(if ($left -eq 0) { '' } elseif ($left -lt 0) { 'the config could not be read back' } else { "$left entr(ies) missing after the write; the app may have rewritten the file" })
                              Backup = $backup; Added = $plan.Missing.Count; Verified = ($left -eq 0) }
}

# ---------------------------------------------------------------------------- the report (pure)

function Format-DuplicateMcpReport {
    param([object[]]$Groups, $Plan, $Applied, [string]$ConfigReason = '')
    $acc = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $c) $acc.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    if (@($Groups).Count -eq 0) {
        & $add 'No MCP server is registered by more than one plugin.' 'Green'
        return @($acc)
    }
    & $add ("MCP servers registered by more than one plugin: {0}" -f @($Groups).Count) 'Cyan'
    foreach ($g in $Groups) {
        & $add ("  {0}" -f $g.Server) 'Yellow'
        foreach ($m in $g.Members) {
            $tag = if ($g.Keep -and $m.Id -eq $g.Keep.Id) { 'KEEP' } elseif ($g.Keep) { 'disable' } else { '?' }
            & $add ("    [{0}] {1}  ({2}, {3})" -f $tag, $m.Id, $m.Transport, $m.Kind) 'Gray'
        }
        & $add ("    Why: {0}" -f $g.Reason) 'Gray'
    }
    & $add '' 'Gray'
    if ($ConfigReason) {
        & $add "Could not read the user config ($ConfigReason); nothing can be planned." 'Red'
        return @($acc)
    }
    if ($Plan) {
        $projects = @($Plan.Missing | ForEach-Object { $_.Project } | Select-Object -Unique)
        if ($Plan.Missing.Count -eq 0) {
            & $add ("All {0} known project(s) already disable the redundant server(s)." -f @($Plan.Projects).Count) 'Green'
        } elseif (-not $Applied) {
            & $add ("To disable: {0} entr(ies) in {1} of {2} known project(s). Plan id: {3}" -f $Plan.Missing.Count, $projects.Count, @($Plan.Projects).Count, $Plan.PlanId) 'Cyan'
            foreach ($p in $projects) {
                $ids = @($Plan.Missing | Where-Object { $_.Project -eq $p } | ForEach-Object { $_.Id })
                & $add ("  {0}: {1}" -f $p, ($ids -join ', ')) 'Gray'
            }
            & $add 'Nothing was changed. On confirmation, run again with -Execute -PlanId <the id above> (the config is backed up first).' 'Gray'
        }
        foreach ($k in $Plan.KeptButDisabled) { & $add ("  Note: {0} disables the one to KEEP ({1}); left as it is." -f $k.Project, $k.Id) 'Yellow' }
    }
    if ($Applied) {
        if ($Applied.Ok) {
            & $add ("Disabled {0} entr(ies). Backup: {1}" -f $Applied.Added, $Applied.Backup) 'Green'
        } else {
            & $add ("NOT applied: {0}{1}" -f $Applied.Reason, $(if ($Applied.Backup) { ". Backup: $($Applied.Backup)" } else { '' })) 'Red'
        }
    }
    & $add 'Limits: the setting is per project (a project opened later needs this run again); open sessions keep their servers until restarted - check with `claude mcp list`.' 'Gray'
    return @($acc)
}

# ---------------------------------------------------------------------------- main
if ($env:ABIOS_DUPMCP_DOTSOURCE) { return }

trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$reg = Get-PluginMcpRegistrations -ClaudeHome $ClaudeHome
if (-not $reg.Ok) { Write-Host "Could not read the installed plugins ($($reg.Reason))." -ForegroundColor Red; exit 1 }
$groups = @(Get-DuplicateMcpGroups -Registrations $reg.Items -Keep $Keep -PreferLocal:$PreferLocal)
$cfgPath = Get-ClaudeConfigPath -ConfigPath $ConfigPath
$cfg = Read-ClaudeConfig -Path $cfgPath
$plan = if ($cfg.Ok -and $groups.Count -gt 0) { Get-McpDisablePlan -Config $cfg -Groups $groups } else { $null }
$applied = $null
if ($Execute -and $groups.Count -gt 0) {
    if (-not $PlanId) { Write-Host 'Refusing: -Execute needs -PlanId, the id the plan printed.' -ForegroundColor Red; exit 1 }
    if (-not $BackupDir) {
        . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
        $BackupDir = Join-Path (Get-AbiosStateDir -Root $HOME) 'backups'
    }
    $applied = Invoke-McpDisable -ConfigPath $cfgPath -Groups $groups -PlanId $PlanId -BackupDir $BackupDir
}
if ($Json) {
    [pscustomobject]@{
        groups = @($groups | ForEach-Object { [pscustomobject]@{ server = $_.Server; keep = $(if ($_.Keep) { $_.Keep.Id } else { $null }); disable = @($_.Disable | ForEach-Object Id); reason = $_.Reason
            members = @($_.Members | ForEach-Object { [pscustomobject]@{ id = $_.Id; transport = $_.Transport; kind = $_.Kind } }) } })
        planId = $(if ($plan) { $plan.PlanId } else { $null }); missing = @($(if ($plan) { $plan.Missing } else { @() }))
        applied = $applied
    } | ConvertTo-Json -Depth 6
} else {
    foreach ($line in (Format-DuplicateMcpReport -Groups $groups -Plan $plan -Applied $applied -ConfigReason $(if ($groups.Count -gt 0 -and -not $cfg.Ok) { $cfg.Reason } else { '' }))) {
        Write-Host $line.Text -ForegroundColor $line.Color
    }
}
if ($applied -and -not $applied.Ok) { exit 1 }
exit 0
