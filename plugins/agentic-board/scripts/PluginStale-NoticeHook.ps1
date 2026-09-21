<#  PluginStale-NoticeHook.ps1 - tell a running session that a plugin it loaded was updated since
    (epic #711, task #714).

    Wired as an auto-registered UserPromptSubmit hook (hooks/hooks.json). A session loads its plugins when
    it starts; an update installs a newer build on disk but the open session keeps the old one, and nothing
    told the user. On each prompt this checks whether any plugin THIS session loaded now has a different
    installed build, and if so shows ONE plain-language notice per (session, plugin, new build):

        - skills / commands / agents / hooks only  -> "type /reload-plugins"
        - the plugin ships an MCP server (or that cannot be told) -> "open a new session"

    The notice is the hook's `systemMessage` (shown to the user, not sent to the model).

    HOW IT KNOWS ITS SESSION: the hook payload carries the session id; sessions/<pid>.json maps it to the
    process id and start time, and the cached build's .in_use/<pid> marker (which must carry that same
    start time) says which builds this process loaded. No process is inspected: this session is, by
    definition, running.

    COST: this runs before every prompt, and a pwsh start alone is about 2 s on the maintainer's machine.
    So hooks.json calls PluginStale-NoticePreCheck.cmd (same idea as Brake-PreCheck.cmd, #572), which
    reads only the session id from the first payload line and skips this script altogether while the
    installed list is unchanged since that session's last CONCLUSIVE check. This script writes the
    per-session stamp the shim reads (Write-ShimStamp: the installed list as this check read it) - only after a conclusive check, so an
    inconclusive one (session or marker not there yet, installed list unreadable) is never remembered.
    Inside this script the same idea remains for the cases the shim lets through: the stamp of the
    installed list (last-write time + size) is kept per session in plugin-notices.json and, while it is
    unchanged, re-checked at most every -RecheckMinutes (30) / -UnknownRecheckMinutes (5). The
    plugin-state library is only loaded when a real check is needed.

    -SessionId  the id the shim already validated (hex and dashes only). When given, stdin is not read.

    NEVER BLOCKS, NEVER THROWS: everything is wrapped, the work is bounded by a time budget, and the script
    always exits 0. Silent when nothing is stale, when the session cannot be identified, or when the notice
    was already shown. One state file, plugin-notices.json, under the shared state directory
    (Get-AbiosStateDir -Root $HOME).

    HONEST LIMIT: only a session that started with a build that already contains this hook can show the
    notice. Sessions older than that (and any that never load hooks) are covered by the session map
    (/board plugins sessions). A session that reloads with /reload-plugins picks the hook up too.

    Dot-source guard: set $env:ABIOS_PLUGINNOTICE_DOTSOURCE=1 to load the functions without reading stdin.  #>
[CmdletBinding()]
param([string]$SessionId = '')

# The wording. One line per plugin; plain language, no file names.
function Format-StaleNotice {
    param([object[]]$Items)
    $lines = foreach ($i in $Items) {
        $loaded = ($i.Loaded -join ', ')
        $head = "Se actualizo el plugin `"$($i.Plugin)`" a la version $($i.Installed) (esta sesion sigue con la $loaded)."
        if ($i.NeedsNewSession) { "$head Trae un servidor MCP (o no pude comprobarlo): abre una sesion nueva para usarla." }
        else { "$head Escribe /reload-plugins para usarla." }
    }
    return (@($lines) -join "`n")
}

function Get-HookClaudeHome([string]$ClaudeHome) {
    if ($ClaudeHome) { return $ClaudeHome }
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

# What an update changes: the installed list. Last-write time + size, '' when it cannot be read.
function Get-InstalledInfo([string]$ClaudeHomeDir) {
    try {
        $fi = [System.IO.FileInfo]::new([System.IO.Path]::Combine($ClaudeHomeDir, 'plugins', 'installed_plugins.json'))
        if (-not $fi.Exists) { return $null }
        return [pscustomobject]@{ Path = $fi.FullName; WriteUtc = $fi.LastWriteTimeUtc; Length = [long]$fi.Length; Bytes = [System.IO.File]::ReadAllBytes($fi.FullName) }
    } catch { return $null }
}
function Get-InstalledStamp([string]$ClaudeHomeDir) {
    $i = Get-InstalledInfo $ClaudeHomeDir
    if (-not $i) { return '' }
    return "$($i.WriteUtc.Ticks)/$($i.Length)"
}

# The state: { Sessions = { <sid> = { "<plugin@marketplace>@<build>" = <when> } }; Checks = { <sid> = { Stamp; At } } }.
# A missing or damaged file reads as empty (worst case: one repeated notice), never as an error.
function Read-NoticeState {
    param([string]$Path)
    $state = @{ Sessions = @{}; Checks = @{} }
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $state }
        $doc = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        if ($doc.sessions) {
            foreach ($s in $doc.sessions.PSObject.Properties) {
                $seen = @{}
                foreach ($k in $s.Value.PSObject.Properties) { $seen[$k.Name] = "$($k.Value)" }
                $state.Sessions[$s.Name] = $seen
            }
        }
        if ($doc.checks) {
            foreach ($c in $doc.checks.PSObject.Properties) { $state.Checks[$c.Name] = @{ Stamp = "$($c.Value.stamp)"; At = [long]$c.Value.at; Full = [bool]$c.Value.full } }
        }
    } catch { return @{ Sessions = @{}; Checks = @{} } }
    return $state
}

# Write the state atomically (temp file, then move) and keep it small: only sessions still in the
# registry (plus this one) survive, and never more than -MaxSessions.
function Write-NoticeState {
    param([string]$Path, [hashtable]$State, [string[]]$KeepSessions, [string]$SessionId, [int]$MaxSessions = 200)
    # Several sessions share this file. Re-read it right before writing and lay ONLY this session's
    # entries over what is there now, so a notice another session recorded in the meantime is not lost.
    $disk = Read-NoticeState -Path $Path
    if ($SessionId -and $State.Sessions.ContainsKey($SessionId)) { $disk.Sessions[$SessionId] = $State.Sessions[$SessionId] }
    if ($SessionId -and $State.Checks.ContainsKey($SessionId)) { $disk.Checks[$SessionId] = $State.Checks[$SessionId] }
    $State = $disk
    $sessions = [ordered]@{}
    foreach ($k in @($State.Sessions.Keys | Where-Object { $KeepSessions -contains $_ } | Select-Object -First $MaxSessions)) { $sessions[$k] = $State.Sessions[$k] }
    $checks = [ordered]@{}
    foreach ($k in @($State.Checks.Keys | Where-Object { $KeepSessions -contains $_ } | Select-Object -First $MaxSessions)) {
        $checks[$k] = [ordered]@{ stamp = $State.Checks[$k].Stamp; at = $State.Checks[$k].At; full = [bool]$State.Checks[$k].Full }
    }
    $json = [ordered]@{ sessions = $sessions; checks = $checks } | ConvertTo-Json -Depth 6 -Compress
    $tmp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($tmp, $json)
    # File.Move with overwrite: unlike Move-Item it never drops the file INSIDE a directory that happens to
    # occupy the path. A failed write throws (it must stop the notice, which would otherwise repeat) into
    # the caller's catch.
    try { [System.IO.File]::Move($tmp, $Path, $true) }
    catch { try { [System.IO.File]::Delete($tmp) } catch { }; throw }
}

# The session id shape the shim accepts (a UUID is 36 characters of hex and dashes). Anything else gets no
# stamp file, which also means an id can never carry a path separator into a file name.
function Test-ShimSessionId([string]$Id) { return ($Id -match '^[0-9A-Fa-f-]{8,64}$') }

# The stamp the .cmd shim compares (see its header): plugin-check\<id>\installed_plugins.json, the bytes of
# Claude's installed list exactly as this check READ them at its start ($Installed comes from Get-InstalledInfo,
# taken before anything is analysed). If the list is rewritten during the check the stamp is the OLD content,
# so the shim sees a difference and runs the hook again - never the other way round. Written only after a
# conclusive check. Also removes the stamps of sessions that are no longer in the registry.
function Write-ShimStamp {
    param([string]$StateDir, [string]$SessionId, $Installed, [string[]]$KeepIds = $null)
    if (-not $Installed -or -not (Test-ShimSessionId $SessionId)) { return }
    $root = [System.IO.Path]::Combine($StateDir, 'plugin-check')
    $dir = [System.IO.Path]::Combine($root, $SessionId)
    [void][System.IO.Directory]::CreateDirectory($dir)
    $path = [System.IO.Path]::Combine($dir, 'installed_plugins.json')
    [System.IO.File]::WriteAllBytes($path, $Installed.Bytes)
    if ($null -ne $KeepIds) {
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($root)) {
            if ($KeepIds -notcontains [System.IO.Path]::GetFileName($d)) { try { [System.IO.Directory]::Delete($d, $true) } catch { } }
        }
    }
}

# The whole decision. Returns the notice text to show, or '' for silence. State is written BEFORE the text
# is returned, so a failure after this point never repeats a notice.
function Invoke-StaleNotice {
    param(
        [string]$StdinText,
        [string]$ClaudeHome,
        [string]$StateDir,
        [int]$BudgetMs = 4000,
        [int]$RecheckMinutes = 30,
        [int]$UnknownRecheckMinutes = 5,
        [datetime]$NowUtc = ([datetime]::UtcNow)
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $payload = $null
    if ($StdinText) { try { $payload = $StdinText | ConvertFrom-Json -ErrorAction Stop } catch { $payload = $null } }
    $sessionId = if ($payload -and $payload.session_id) { "$($payload.session_id)" } else { '' }
    if (-not $sessionId -or -not $StateDir) { return '' }

    $claudeDir = Get-HookClaudeHome $ClaudeHome
    # Taken BEFORE anything is analysed (the bytes included): if the file is rewritten during this check, the
    # shim stamp holds the old content and the shim runs the hook again.
    $installedInfo = Get-InstalledInfo $claudeDir
    $stamp = if ($installedInfo) { "$($installedInfo.WriteUtc.Ticks)/$($installedInfo.Length)" } else { '' }
    $statePath = Join-Path $StateDir 'plugin-notices.json'
    $state = Read-NoticeState -Path $statePath

    # Fast path: the installed list has not changed since this session was last checked.
    if ($stamp -and $state.Checks.ContainsKey($sessionId)) {
        $last = $state.Checks[$sessionId]
        # The time is kept as UTC ticks: ConvertFrom-Json turns an ISO date string into a culture-formatted one.
        if ($last.Stamp -eq $stamp -and $last.At -gt 0) {
            # An inconclusive check (session not found yet, no marker yet, installed list unreadable) is
            # only trusted briefly: the first prompt can race ahead of the records it needs.
            $window = if ($last.Full) { $RecheckMinutes } else { $UnknownRecheckMinutes }
            $age = ($NowUtc.Ticks - $last.At) / [double][TimeSpan]::TicksPerMinute
            if ($age -ge 0 -and $age -lt $window) {
                # A conclusive earlier check still stands: make sure the shim knows (its stamp may be missing).
                if ($last.Full) { try { Write-ShimStamp -StateDir $StateDir -SessionId $sessionId -Installed $installedInfo } catch { } }
                return ''
            }
        }
    }

    # A real check: only now is the state library loaded (the parse is the expensive part).
    . (Join-Path $PSScriptRoot 'PluginState.ps1')
    $reg = Read-ClaudeSessions -ClaudeHome $ClaudeHome
    $me = @($reg.Sessions | Where-Object { $_.SessionId -eq $sessionId }) | Select-Object -First 1
    $fresh = @()
    $definitive = $false
    if ($me) {
        $inst = Get-InstalledPluginEntries -ClaudeHome $ClaudeHome
        if ($inst.Ok) {
            $markers = @(Read-VersionMarkers -ClaudeHome $ClaudeHome -OnlyPid $me.Pid)
            $st = Get-SessionPluginState -Session $me -Markers $markers -InstalledEntries $inst.Entries
            $definitive = ($st.State -ne 'unknown')
            if ($st.State -eq 'stale') {
                if (-not $state.Sessions.ContainsKey($sessionId)) { $state.Sessions[$sessionId] = @{} }
                $fresh = @($st.Stale | Where-Object { -not $state.Sessions[$sessionId].ContainsKey("$($_.Key)@$($_.Installed)") })
            }
        }
    }
    if ($clock.ElapsedMilliseconds -gt $BudgetMs) { return '' }

    $stampNow = $NowUtc.ToString('o')   # a readable record of when a notice was shown
    foreach ($f in $fresh) { $state.Sessions[$sessionId]["$($f.Key)@$($f.Installed)"] = $stampNow }
    if ($stamp) { $state.Checks[$sessionId] = @{ Stamp = $stamp; At = [long]$NowUtc.Ticks; Full = $definitive } }
    $keepIds = @($reg.Sessions | ForEach-Object { $_.SessionId }) + @($sessionId)
    Write-NoticeState -Path $statePath -State $state -KeepSessions $keepIds -SessionId $sessionId
    # Only now (the notice, if any, is recorded) and only for a CONCLUSIVE check may the shim skip next time.
    if ($definitive) { try { Write-ShimStamp -StateDir $StateDir -SessionId $sessionId -Installed $installedInfo -KeepIds $keepIds } catch { } }
    if ($fresh.Count -eq 0) { return '' }
    return (Format-StaleNotice -Items $fresh)
}

if ($env:ABIOS_PLUGINNOTICE_DOTSOURCE) { return }

# Main. A UserPromptSubmit hook must never disturb the prompt: swallow everything, always exit 0.
try {
    $raw = ''
    if ($SessionId) {
        # Called by the shim with an id it validated; re-validate (the script can also be run by hand).
        if (-not (Test-ShimSessionId $SessionId)) { exit 0 }
        $raw = (@{ session_id = $SessionId } | ConvertTo-Json -Compress)
    } else {
        if (-not [Console]::IsInputRedirected) { exit 0 }
        try { $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false)).ReadToEnd() } catch { $raw = '' }
    }

    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $dir = Get-AbiosStateDir -Root $HOME
    if ($dir) {
        $notice = Invoke-StaleNotice -StdinText $raw -ClaudeHome '' -StateDir $dir
        if ($notice) {
            $out = @{ systemMessage = $notice } | ConvertTo-Json -Compress
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            Write-Output $out
        }
    }
} catch {
    # swallowed on purpose
}
exit 0
