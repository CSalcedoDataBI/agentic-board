<#  PluginState.ps1 - read-only view of what Claude Code has installed and which open sessions
    still run an old build (epic #711). Function definitions only; dot-source it.

    Everything here reads files under the Claude home (default ~/.claude, or CLAUDE_CONFIG_DIR,
    or an explicit -ClaudeHome). Nothing is written except by Remove-PluginVersionDir, the one
    deleting function, which re-checks every guard right before it acts.

    The facts it builds on (verified against a real ~/.claude on 2026-09-21):
      - plugins/installed_plugins.json   plugins["<plugin>@<marketplace>"] = [ {scope, version,
                                         installPath, gitCommitSha, ...} ]
      - plugins/known_marketplaces.json  per marketplace: source, installLocation, autoUpdate
      - plugins/cache/<m>/<p>/<v>/       one directory per build ever installed
        .in_use/<pid>                    {"pid":N,"procStartFt":"<FILETIME>"} written by every process
                                         that loaded that build. Markers of dead processes are never
                                         cleaned, so a bare PID proves nothing.
      - sessions/<pid>.json              the live-session registry (pid, sessionId, cwd, name,
                                         procStart = the same FILETIME text the markers carry)

    LIVENESS is never "does this pid exist". A pid is reused by Windows, so the process START TIME
    must match what was recorded. That rule already lives in Board-Work.ps1
    (Test-SessionStartConsistent, #520/#557) and is REUSED here, not re-implemented: the recorded
    FILETIME becomes the registration stamp that helper compares the live process against. The
    caller dot-sources Board-Work.ps1 (with its documented guard) first; when that helper is not
    loaded every liveness answer is 'unknown', which every caller treats as "keep / cannot say" -
    never as "gone" and never as "fine".

    Three-valued on purpose: live | dead | unknown. Deleting anything, or calling a session
    up to date, requires a positive answer; unknown is neither.  #>
[CmdletBinding()]
param()

# ---------------------------------------------------------------------------- paths + JSON

function Get-ClaudeHomeDir {
    param([string]$ClaudeHome)
    if ($ClaudeHome) { return $ClaudeHome }
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

# Read + parse one JSON file. Never throws: the caller learns WHY it failed (missing vs unreadable),
# because "cannot read it" must fail closed in the callers and "does not exist" often does not.
function Read-JsonFileSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'missing' }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'unreadable' }
    }
    if ($null -eq $data) { return [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'empty' } }
    return [pscustomobject]@{ Ok = $true; Data = $data; Reason = '' }
}

# The last path segment, whichever separator the JSON was written with (a Windows path read on Linux).
function Get-PathLeafText([string]$Path) {
    if (-not $Path) { return '' }
    $t = $Path -replace '[\\/]+$', ''
    return (($t -split '[\\/]') | Select-Object -Last 1)
}

# 'plugin@marketplace' -> parts. The marketplace is what follows the LAST '@'.
function Split-PluginKey([string]$Key) {
    $i = "$Key".LastIndexOf('@')
    if ($i -le 0 -or $i -ge $Key.Length - 1) { return $null }
    return [pscustomobject]@{ Plugin = $Key.Substring(0, $i); Marketplace = $Key.Substring($i + 1) }
}

# A FILETIME as digits, or '' when it is not one. Text compare is exact and needs no big-int parsing.
function ConvertTo-FileTimeText($Value) {
    $t = "$Value".Trim()
    if ($t -match '^\d{12,20}$') { return $t }
    return ''
}

# ---------------------------------------------------------------------------- registries

# Every installed plugin build, from installed_plugins.json.
#   { Ok; Reason; Entries = @{ Key; Plugin; Marketplace; Scope; Version; Sha; InstallPath } }
function Get-InstalledPluginEntries {
    param([string]$ClaudeHome)
    $path = Join-Path (Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'plugins') 'installed_plugins.json'
    $r = Read-JsonFileSafe $path
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "installed_plugins.json: $($r.Reason)"; Entries = @() } }
    $plugins = $r.Data.plugins
    if ($null -eq $plugins) { return [pscustomobject]@{ Ok = $false; Reason = 'installed_plugins.json has no plugins section'; Entries = @() } }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($prop in $plugins.PSObject.Properties) {
        $parts = Split-PluginKey $prop.Name
        if (-not $parts) { continue }
        foreach ($e in @($prop.Value)) {
            if ($null -eq $e) { continue }
            $scope = if ($e.scope) { "$($e.scope)" } else { 'user' }
            $entries.Add([pscustomobject]@{
                Key = $prop.Name; Plugin = $parts.Plugin; Marketplace = $parts.Marketplace; Scope = $scope
                Version = "$($e.version)"; Sha = "$($e.gitCommitSha)"; InstallPath = "$($e.installPath)"
            })
        }
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Entries = @($entries) }
}

# Every registered marketplace, from known_marketplaces.json.
#   { Ok; Reason; Items = @{ Name; SourceKind; InstallLocation; AutoUpdate } }
function Get-KnownMarketplaces {
    param([string]$ClaudeHome)
    $path = Join-Path (Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'plugins') 'known_marketplaces.json'
    $r = Read-JsonFileSafe $path
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "known_marketplaces.json: $($r.Reason)"; Items = @() } }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($prop in $r.Data.PSObject.Properties) {
        $src = $prop.Value.source
        $kind = if ($src -and $src.source) { "$($src.source)" } else { '' }
        $items.Add([pscustomobject]@{
            Name = $prop.Name; SourceKind = $kind; InstallLocation = "$($prop.Value.installLocation)"
            AutoUpdate = [bool]$prop.Value.autoUpdate
        })
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Items = @($items) }
}

# The live-session registry: sessions/<pid>.json. Files that are not <pid>.json (the .key files
# beside them) and files that do not parse are counted, never listed.
#   { Sessions = @{ Pid; SessionId; Cwd; Name; Status; ProcStart; ClaudeVersion }; Unreadable }
function Read-ClaudeSessions {
    param([string]$ClaudeHome)
    $dir = Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'sessions'
    $sessions = [System.Collections.Generic.List[object]]::new()
    $bad = 0
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch '^(\d+)\.json$') { continue }
            $filePid = [long]$Matches[1]
            $r = Read-JsonFileSafe $f.FullName
            $recPid = 0L
            if ($r.Ok) { try { $recPid = [long]$r.Data.pid } catch { $recPid = 0L } }
            # A record whose pid disagrees with its own file name is not trusted to describe that process.
            if (-not $r.Ok -or $recPid -ne $filePid) { $bad++; continue }
            $sessions.Add([pscustomobject]@{
                Pid = $filePid; SessionId = "$($r.Data.sessionId)"; Cwd = "$($r.Data.cwd)"; Name = "$($r.Data.name)"
                Status = "$($r.Data.status)"; ProcStart = (ConvertTo-FileTimeText $r.Data.procStart)
                ClaudeVersion = "$($r.Data.version)"
            })
        }
    }
    return [pscustomobject]@{ Sessions = @($sessions); Unreadable = $bad }
}

# ---------------------------------------------------------------------------- the .in_use markers

# One marker file -> { Pid; StartFt; Valid; Reason; File }. Valid needs a positive pid that agrees
# with the file name AND a start time: without the start time the marker cannot be told apart from
# a recycled pid, so it can never prove anything (callers read Valid=$false as "cannot tell").
function ConvertFrom-MarkerFile {
    param($File)
    $bad = { param($why) [pscustomobject]@{ Pid = 0L; StartFt = ''; Valid = $false; Reason = $why; File = $File.FullName } }
    if ($File.PSIsContainer) { return (& $bad 'not a file') }
    $r = Read-JsonFileSafe $File.FullName
    if (-not $r.Ok) { return (& $bad "marker $($r.Reason)") }
    $p = 0L
    try { $p = [long]$r.Data.pid } catch { $p = 0L }
    $ft = ConvertTo-FileTimeText $r.Data.procStartFt
    if ($p -le 0) { return (& $bad 'no pid') }
    if ("$p" -ne $File.Name) { return (& $bad 'pid does not match the file name') }
    if (-not $ft) { return (& $bad 'no start time') }
    return [pscustomobject]@{ Pid = $p; StartFt = $ft; Valid = $true; Reason = ''; File = $File.FullName }
}

# The markers of ONE cached build. Ok=$false when the .in_use folder exists but cannot be listed.
function Read-DirMarkers {
    param([string]$VersionDir)
    $iu = Join-Path $VersionDir '.in_use'
    if (-not (Test-Path -LiteralPath $iu)) { return [pscustomobject]@{ Ok = $true; Markers = @() } }
    if (-not (Test-Path -LiteralPath $iu -PathType Container)) { return [pscustomobject]@{ Ok = $false; Markers = @() } }
    try { $files = @(Get-ChildItem -LiteralPath $iu -Force -ErrorAction Stop) }
    catch { return [pscustomobject]@{ Ok = $false; Markers = @() } }
    return [pscustomobject]@{ Ok = $true; Markers = @($files | ForEach-Object { ConvertFrom-MarkerFile $_ }) }
}

# Every cached build directory: cache/<marketplace>/<plugin>/<version>.
function Get-CacheVersionDirs {
    param([string]$ClaudeHome)
    $cache = Join-Path (Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'plugins') 'cache'
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) { return @() }
    foreach ($m in @(Get-ChildItem -LiteralPath $cache -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($p in @(Get-ChildItem -LiteralPath $m.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($v in @(Get-ChildItem -LiteralPath $p.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                $out.Add([pscustomobject]@{ Marketplace = $m.Name; Plugin = $p.Name; Version = $v.Name; Path = $v.FullName })
            }
        }
    }
    return @($out)
}

# Markers across the whole cache, tagged with the build they sit in. -OnlyPid narrows the read to
# the one marker file a single process would have written (the in-session hook uses it to stay cheap).
function Read-VersionMarkers {
    param([string]$ClaudeHome, [long]$OnlyPid = 0)
    $out = [System.Collections.Generic.List[object]]::new()
    $dirs = @()
    if ($OnlyPid -gt 0) {
        # The hot path (one process, every prompt): straight .NET listing and one file probe per build,
        # several times cheaper than the provider cmdlets over a cache with hundreds of folders.
        $cache = [System.IO.Path]::Combine((Get-ClaudeHomeDir $ClaudeHome), 'plugins', 'cache')
        $found = [System.Collections.Generic.List[object]]::new()
        try {
            if ([System.IO.Directory]::Exists($cache)) {
                foreach ($m in [System.IO.Directory]::EnumerateDirectories($cache)) {
                    foreach ($p in [System.IO.Directory]::EnumerateDirectories($m)) {
                        foreach ($v in [System.IO.Directory]::EnumerateDirectories($p)) {
                            if ([System.IO.File]::Exists([System.IO.Path]::Combine($v, '.in_use', "$OnlyPid"))) {
                                $found.Add([pscustomobject]@{ Marketplace = (Split-Path -Leaf $m); Plugin = (Split-Path -Leaf $p); Version = (Split-Path -Leaf $v); Path = $v })
                            }
                        }
                    }
                }
            }
        } catch { }
        $dirs = @($found)
    } else {
        $dirs = @(Get-CacheVersionDirs -ClaudeHome $ClaudeHome)
    }
    foreach ($d in $dirs) {
        $iu = Join-Path $d.Path '.in_use'
        if (-not (Test-Path -LiteralPath $iu -PathType Container)) { continue }
        $files = @()
        if ($OnlyPid -gt 0) {
            $one = Join-Path $iu "$OnlyPid"
            if (Test-Path -LiteralPath $one -PathType Leaf) { $files = @(Get-Item -LiteralPath $one -Force) }
        } else {
            $files = @(Get-ChildItem -LiteralPath $iu -Force -ErrorAction SilentlyContinue)
        }
        foreach ($f in $files) {
            $m = ConvertFrom-MarkerFile $f
            $out.Add([pscustomobject]@{
                Marketplace = $d.Marketplace; Plugin = $d.Plugin; Version = $d.Version; VersionDir = $d.Path
                Pid = $m.Pid; StartFt = $m.StartFt; Valid = $m.Valid; File = $m.File
            })
        }
    }
    return @($out)
}

# ---------------------------------------------------------------------------- liveness

# Is the process that wrote this record still the one running under that pid?  live | dead | unknown
#  - no process with that pid                        -> dead
#  - process exists, started later than the record   -> dead  (a recycled pid; Test-SessionStartConsistent)
#  - process exists and started no later             -> live
#  - no usable start time on either side, or the reused helper is not loaded -> unknown
# -GetProcess is the seam: it returns an object with a .StartTime (or $null when there is no such pid).
function Get-HolderLiveness {
    param(
        [long]$ProcessId,
        [string]$StartFt,
        [scriptblock]$GetProcess = { param($id) Get-Process -Id $id -ErrorAction SilentlyContinue }
    )
    if ($ProcessId -le 0) { return 'unknown' }
    $ft = ConvertTo-FileTimeText $StartFt
    if (-not $ft) { return 'unknown' }
    if (-not (Get-Command Test-SessionStartConsistent -ErrorAction SilentlyContinue)) { return 'unknown' }
    $proc = $null
    try { $proc = & $GetProcess $ProcessId } catch { return 'unknown' }
    if (-not $proc) { return 'dead' }
    $start = $null
    try { $start = $proc.StartTime } catch { $start = $null }   # protected processes refuse StartTime
    if ($null -eq $start) { return 'unknown' }
    $stamp = ''
    try { $stamp = [datetime]::FromFileTime([long]$ft).ToString('yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture) } catch { return 'unknown' }
    if (Test-SessionStartConsistent -ProcessStart $start -Started $stamp) { return 'live' }
    return 'dead'
}

# ---------------------------------------------------------------------------- MCP servers

# Does this plugin build ship an MCP server?  $true | $false | $null (cannot tell).
# Claude Code reconnects MCP servers only when a session starts, so such a plugin needs a NEW
# session; skills, commands, agents and hooks are picked up by /reload-plugins.
# Looks for a .mcp.json at the plugin root or an mcpServers entry in .claude-plugin/plugin.json.
# (A server declared only in the marketplace entry is not visible from the build: known limit.)
function Test-PluginShipsMcp {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $Dir '.mcp.json') -PathType Leaf) { return $true }
    $pj = Join-Path (Join-Path $Dir '.claude-plugin') 'plugin.json'
    if (-not (Test-Path -LiteralPath $pj -PathType Leaf)) { return $false }
    $r = Read-JsonFileSafe $pj
    if (-not $r.Ok) { return $null }
    $srv = $r.Data.mcpServers
    if ($null -eq $srv) { return $false }
    if ($srv -is [string]) { return [bool]$srv }
    return (@($srv.PSObject.Properties).Count -gt 0 -or @($srv).Count -gt 0)
}

# ---------------------------------------------------------------------------- session vs installed

# What one LIVE session loaded, against what is installed now.
#   State  stale | current | unknown
#   unknown = no marker of this exact process (pid AND start time) exists anywhere. It is never
#   "current": a session we cannot see into must not read as up to date.
#   Stale  one row per plugin the session loaded whose installed build is a different one:
#          { Key; Plugin; Marketplace; Loaded (versions); Installed; NeedsNewSession }
# A plugin no longer installed at all is not stale (nothing to reload to).
# A plugin is up to date when ANY installed build of it is among the builds the session loaded, so a
# session that reloaded onto the new build (and left the old marker behind) reads current.
function Get-SessionPluginState {
    param($Session, [object[]]$Markers, [object[]]$InstalledEntries)
    $start = ConvertTo-FileTimeText $Session.ProcStart
    $mine = @()
    if ($start) {
        $mine = @($Markers | Where-Object { $_.Valid -and $_.Pid -eq $Session.Pid -and $_.StartFt -eq $start })
    }
    if ($mine.Count -eq 0) { return [pscustomobject]@{ State = 'unknown'; Stale = @(); Checked = 0 } }

    $stale = [System.Collections.Generic.List[object]]::new()
    $checked = 0
    foreach ($grp in ($mine | Group-Object { "$($_.Plugin)@$($_.Marketplace)" })) {
        $key = $grp.Name
        $installed = @($InstalledEntries | Where-Object { $_.Key -eq $key })
        if ($installed.Count -eq 0) { continue }
        $checked++
        $loaded = @($grp.Group | ForEach-Object { $_.Version } | Select-Object -Unique)
        $installedVersions = @($installed | ForEach-Object { Get-PathLeafText $_.InstallPath; $_.Version } | Where-Object { $_ } | Select-Object -Unique)
        if (@($loaded | Where-Object { $installedVersions -contains $_ }).Count -gt 0) { continue }
        $target = ($installed | Where-Object { $_.Scope -eq 'user' } | Select-Object -First 1)
        if (-not $target) { $target = $installed[0] }
        # A new session is needed when either build ships MCP servers - or when we cannot tell.
        $mcpOld = Test-PluginShipsMcp $grp.Group[0].VersionDir
        $mcpNew = Test-PluginShipsMcp $target.InstallPath
        $needsNew = ($mcpOld -ne $false) -or ($mcpNew -ne $false)
        $parts = Split-PluginKey $key
        $stale.Add([pscustomobject]@{
            Key = $key; Plugin = $parts.Plugin; Marketplace = $parts.Marketplace; Loaded = $loaded
            Installed = (Get-PathLeafText $target.InstallPath); NeedsNewSession = $needsNew
        })
    }
    if ($checked -eq 0) { return [pscustomobject]@{ State = 'unknown'; Stale = @(); Checked = 0 } }
    $state = if ($stale.Count -gt 0) { 'stale' } else { 'current' }
    return [pscustomobject]@{ State = $state; Stale = @($stale); Checked = $checked }
}

# Every session that is provably open, with its plugin state. Sessions that are gone are dropped
# without their id or folder ever being read into the result; sessions whose liveness cannot be
# confirmed are only COUNTED (UnknownLiveness), so no id/folder of a maybe-dead session is shown.
#   { Ok; Reason; Sessions = @{ Pid; Name; Cwd; Status; ClaudeVersion; State; Stale }; DeadIgnored;
#     UnknownLiveness; Unreadable }
function Get-LiveSessionMap {
    param([string]$ClaudeHome, [scriptblock]$GetProcess)
    $inst = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
    if (-not $inst.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $inst.Reason; Sessions = @(); DeadIgnored = 0; UnknownLiveness = 0; Unreadable = 0 }
    }
    $reg = Read-ClaudeSessions -ClaudeHome $ClaudeHome
    $rows = [System.Collections.Generic.List[object]]::new()
    $dead = 0; $unknown = 0
    foreach ($s in $reg.Sessions) {
        $args_ = @{ ProcessId = $s.Pid; StartFt = $s.ProcStart }
        if ($GetProcess) { $args_.GetProcess = $GetProcess }
        $alive = Get-HolderLiveness @args_
        if ($alive -eq 'dead') { $dead++; continue }
        if ($alive -ne 'live') { $unknown++; continue }
        $markers = @(Read-VersionMarkers -ClaudeHome $ClaudeHome -OnlyPid $s.Pid)
        $st = Get-SessionPluginState -Session $s -Markers $markers -InstalledEntries $inst.Entries
        $rows.Add([pscustomobject]@{
            Pid = $s.Pid; Name = $s.Name; Cwd = $s.Cwd; Status = $s.Status; ClaudeVersion = $s.ClaudeVersion
            State = $st.State; Stale = $st.Stale
        })
    }
    return [pscustomobject]@{
        Ok = $true; Reason = ''; Sessions = @($rows); DeadIgnored = $dead; UnknownLiveness = $unknown; Unreadable = $reg.Unreadable
    }
}

# ---------------------------------------------------------------------------- safe cleanup of old builds

# The real path of something that exists (Get-Item expands 8.3 short names such as CRISTO~1, which
# Resolve-Path and string compares do not), or $null.
function Get-CanonicalPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $null }
    return ($item.FullName -replace '[\\/]+$', '')
}

function Test-IsLinkItem($Item) {
    if ($null -eq $Item) { return $true }
    if ($Item.LinkType) { return $true }
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Is Child strictly inside Parent (both must exist; canonicalised first)?  -DirectChild demands it
# be exactly one level down. A path equal to the parent is NOT inside it.
function Test-PathStrictlyInside {
    param([string]$Child, [string]$Parent, [switch]$DirectChild)
    $c = Get-CanonicalPath $Child
    $p = Get-CanonicalPath $Parent
    if (-not $c -or -not $p) { return $false }
    $cmp = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($c.Length -le $p.Length + 1) { return $false }
    if (-not $c.StartsWith($p + $sep, $cmp)) { return $false }
    if ($DirectChild) { return (($c.Substring($p.Length + 1)) -notmatch '[\\/]') }
    return $true
}

function Get-DirSizeBytes([string]$Path) {
    try { return [long](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { return 0L }
}

# Every cached build, each with a verdict: remove | keep + the reason. A build is removable only when
# ALL of these hold - any doubt is keep:
#   1. installed_plugins.json is readable and non-empty (else nothing can be judged: refuse everything)
#   2. it is not the installed build of any entry (by real path, or by plugin@marketplace + version)
#   3. every .in_use marker is readable AND its holder is provably dead (pid gone, or pid reused by a
#      process that started later). A live holder, an unknown one, or a marker that cannot be read keeps it.
#   4. its real path is strictly inside <ClaudeHome>/plugins/cache/<m>/<p>/, and neither it nor its
#      parents nor anything inside is a link/junction (deleting through a link could leave the cache)
#   5. it was not touched within -GraceMinutes (an install in progress is not yet in installed_plugins.json)
#   { Ok; Reason; Items = @{ Marketplace; Plugin; Version; Path; Action; Category; Reason; SizeBytes } }
#   Category: removable | installed | in-use | unknown-holder | link | outside | recent
function Get-VersionCleanupPlan {
    param(
        [string]$ClaudeHome,
        [scriptblock]$GetProcess,
        [int]$GraceMinutes = 60,
        [datetime]$Now = (Get-Date)
    )
    $refuse = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why; Items = @() } }
    $inst = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
    if (-not $inst.Ok) { return (& $refuse "no pude leer que plugins estan instalados ($($inst.Reason))") }
    if (@($inst.Entries).Count -eq 0) { return (& $refuse 'la lista de plugins instalados esta vacia; no puedo distinguir lo viejo de lo instalado') }

    $home_ = Get-ClaudeHomeDir $ClaudeHome
    $cacheRoot = Join-Path (Join-Path $home_ 'plugins') 'cache'
    if (-not (Test-Path -LiteralPath $cacheRoot)) { return [pscustomobject]@{ Ok = $true; Reason = ''; Items = @() } }
    if (Test-IsLinkItem (Get-Item -LiteralPath $cacheRoot -Force)) { return (& $refuse 'la carpeta de versiones guardadas es un enlace') }

    $installedReal = @($inst.Entries | ForEach-Object { Get-CanonicalPath $_.InstallPath } | Where-Object { $_ })
    $cmp = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $liveMemo = @{}
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($d in @(Get-CacheVersionDirs -ClaudeHome $ClaudeHome)) {
        $verdict = { param($action, $cat, $why, $size)
            [pscustomobject]@{ Marketplace = $d.Marketplace; Plugin = $d.Plugin; Version = $d.Version; Path = $d.Path
                               Action = $action; Category = $cat; Reason = $why; SizeBytes = $size } }
        $keep = { param($cat, $why) & $verdict 'keep' $cat $why 0L }

        # (4) location + links, before anything else is even read from the directory
        $vItem = Get-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue
        $pDir  = Split-Path -Parent $d.Path
        $mDir  = Split-Path -Parent $pDir
        $pItem = Get-Item -LiteralPath $pDir -Force -ErrorAction SilentlyContinue
        $mItem = Get-Item -LiteralPath $mDir -Force -ErrorAction SilentlyContinue
        if ((Test-IsLinkItem $vItem) -or (Test-IsLinkItem $pItem) -or (Test-IsLinkItem $mItem)) { $items.Add((& $keep 'link' 'es un enlace, no una carpeta real')); continue }
        if (-not (Test-PathStrictlyInside -Child $d.Path -Parent $pDir -DirectChild) -or
            -not (Test-PathStrictlyInside -Child $pDir -Parent $mDir -DirectChild) -or
            -not (Test-PathStrictlyInside -Child $mDir -Parent $cacheRoot -DirectChild)) {
            $items.Add((& $keep 'outside' 'su ruta real queda fuera de la carpeta de versiones guardadas')); continue
        }
        $inner = @(Get-ChildItem -LiteralPath $d.Path -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
        if ($inner.Count -gt 0) { $items.Add((& $keep 'link' 'contiene enlaces')); continue }

        # (2) installed
        $real = Get-CanonicalPath $d.Path
        $isInstalled = $false
        foreach ($e in $inst.Entries) {
            if ($e.Key -eq "$($d.Plugin)@$($d.Marketplace)" -and (Get-PathLeafText $e.InstallPath) -eq $d.Version) { $isInstalled = $true }
            if ($e.Key -eq "$($d.Plugin)@$($d.Marketplace)" -and $e.Version -eq $d.Version) { $isInstalled = $true }
        }
        if (-not $isInstalled -and $real) { foreach ($ir in $installedReal) { if ($cmp.Equals($ir, $real)) { $isInstalled = $true } } }
        if ($isInstalled) { $items.Add((& $keep 'installed' 'es la version instalada')); continue }

        # (3) holders
        $mk = Read-DirMarkers -VersionDir $d.Path
        if (-not $mk.Ok) { $items.Add((& $keep 'unknown-holder' 'no pude leer quien la usa')); continue }
        $holder = $null
        $holderCat = 'unknown-holder'
        foreach ($m in $mk.Markers) {
            if (-not $m.Valid) { $holder = "un registro de uso ilegible ($($m.Reason))"; break }
            $memoKey = "$($m.Pid)|$($m.StartFt)"
            if (-not $liveMemo.ContainsKey($memoKey)) {
                $a = @{ ProcessId = $m.Pid; StartFt = $m.StartFt }
                if ($GetProcess) { $a.GetProcess = $GetProcess }
                $liveMemo[$memoKey] = Get-HolderLiveness @a
            }
            if ($liveMemo[$memoKey] -eq 'live')    { $holder = "la usa una sesion abierta (proceso $($m.Pid))"; $holderCat = 'in-use'; break }
            if ($liveMemo[$memoKey] -ne 'dead')    { $holder = "no pude confirmar si el proceso $($m.Pid) sigue abierto"; break }
        }
        if ($holder) { $items.Add((& $keep $holderCat $holder)); continue }

        # (5) grace
        $touched = $vItem.LastWriteTime
        $iuItem = Get-Item -LiteralPath (Join-Path $d.Path '.in_use') -Force -ErrorAction SilentlyContinue
        if ($iuItem -and $iuItem.LastWriteTime -gt $touched) { $touched = $iuItem.LastWriteTime }
        if (($Now - $touched).TotalMinutes -lt $GraceMinutes) { $items.Add((& $keep 'recent' "se toco hace menos de $GraceMinutes minutos")); continue }

        $items.Add((& $verdict 'remove' 'removable' 'nadie la usa y no es la version instalada' (Get-DirSizeBytes $d.Path)))
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Items = @($items) }
}

# The ONE deleting function. It trusts nothing from the plan: the target must still be a real
# directory (not a link), exactly three levels under the real cache root, and free of links inside.
# -WhatIf-style dry runs are the caller's job (it simply does not call this).
#   { Removed; Reason }
function Remove-PluginVersionDir {
    param([Parameter(Mandatory)][string]$Path, [string]$ClaudeHome)
    $cacheRoot = Join-Path (Join-Path (Get-ClaudeHomeDir $ClaudeHome) 'plugins') 'cache'
    $no = { param($why) [pscustomobject]@{ Removed = $false; Reason = $why } }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) { return (& $no 'no es una carpeta existente') }
    if (Test-IsLinkItem $item) { return (& $no 'es un enlace') }
    $pDir = Split-Path -Parent $item.FullName
    $mDir = Split-Path -Parent $pDir
    # A parent that became a junction would make the string-prefix checks below pass while the delete
    # walks through it to somewhere else (Get-Item reports the path as spelled, not where it leads).
    foreach ($up in @($pDir, $mDir, $cacheRoot)) {
        if (Test-IsLinkItem (Get-Item -LiteralPath $up -Force -ErrorAction SilentlyContinue)) { return (& $no 'una carpeta que la contiene es un enlace') }
    }
    if (-not (Test-PathStrictlyInside -Child $item.FullName -Parent $pDir -DirectChild) -or
        -not (Test-PathStrictlyInside -Child $pDir -Parent $mDir -DirectChild) -or
        -not (Test-PathStrictlyInside -Child $mDir -Parent $cacheRoot -DirectChild)) {
        return (& $no 'su ruta real no queda dentro de la carpeta de versiones guardadas')
    }
    if (@(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue).Count -gt 0) {
        return (& $no 'contiene enlaces')
    }
    try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop }
    catch { return (& $no "no se pudo borrar: $($_.Exception.Message)") }
    if (Test-Path -LiteralPath $item.FullName) { return (& $no 'sigue existiendo despues de borrar') }
    return [pscustomobject]@{ Removed = $true; Reason = '' }
}

# Plan -> deletions, with the plan RE-DERIVED first. The plan a person looked at is a moment old: since
# then a session may have loaded the build or an update may have installed it. So a fresh plan is made
# right before deleting, and only a build that is removable in BOTH is attempted; each is then
# re-verified by Remove-PluginVersionDir. { Removed = items; Failed = items (with FailReason) }
function Invoke-PluginCleanup {
    param($Plan, [string]$ClaudeHome, [scriptblock]$GetProcess, [int]$GraceMinutes = 60)
    $removed = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()
    $args_ = @{ ClaudeHome = $ClaudeHome; GraceMinutes = $GraceMinutes }
    if ($GetProcess) { $args_.GetProcess = $GetProcess }
    $fresh = Get-VersionCleanupPlan @args_
    $stillOk = @{}
    if ($fresh.Ok) { foreach ($f in @($fresh.Items | Where-Object { $_.Action -eq 'remove' })) { $stillOk[$f.Path] = $true } }
    foreach ($i in @($Plan.Items | Where-Object { $_.Action -eq 'remove' })) {
        if (-not $stillOk.ContainsKey($i.Path)) {
            $i | Add-Member -NotePropertyName FailReason -NotePropertyValue 'ya no cumple las condiciones para borrarla (se volvio a comprobar justo antes)' -Force
            $failed.Add($i); continue
        }
        $r = Remove-PluginVersionDir -Path $i.Path -ClaudeHome $ClaudeHome
        if ($r.Removed) { $removed.Add($i) }
        else { $i | Add-Member -NotePropertyName FailReason -NotePropertyValue $r.Reason -Force; $failed.Add($i) }
    }
    return [pscustomobject]@{ Removed = @($removed); Failed = @($failed) }
}