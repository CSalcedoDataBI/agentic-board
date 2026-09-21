#Requires -Modules Pester
<#  Plugin state readers, liveness, session-vs-installed staleness and the session map (epic #711,
    tasks #713 and the shared core of #712/#714/#715).

    Every test drives the real functions over a FABRICATED Claude home (installed_plugins.json,
    known_marketplaces.json, sessions/*.json, cache/<m>/<p>/<v>/.in_use/<pid>) - never the real
    ~/.claude. Liveness is exercised two ways: with the Pester host itself (a live process with a real
    start time) and with a fake process table (-GetProcess), so a recycled pid, a dead pid and an
    unreadable start time are all reproduced exactly. Nothing mocks the function under test.  #>

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..' 'scripts'
    # The recycled-pid rule (Test-SessionStartConsistent) lives in Board-Work.ps1 and is what the state
    # library reuses for liveness; load it the way Board-Doctor does.
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . (Join-Path $scripts 'Board-Work.ps1')
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    . (Join-Path $scripts 'PluginState.ps1')
    $env:ABIOS_SESSIONMAP_DOTSOURCE = '1'
    . (Join-Path $scripts 'Get-PluginSessionMap.ps1')
    $env:ABIOS_SESSIONMAP_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    function script:New-Fx { New-FakeHome -Root (Join-Path $TestDrive ("h" + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    $script:MyFt = Get-MyFileTimeText
}

Describe 'Get-HolderLiveness - pid AND start time, three-valued' {
    It 'a live process whose start time matches is live' {
        Get-HolderLiveness -ProcessId $PID -StartFt $script:MyFt | Should -Be 'live'
    }
    It 'a recycled pid is DEAD: the pid exists but started long after the recorded start' {
        $earlier = [string]([datetime]::FromFileTime([long]$script:MyFt).AddHours(-3).ToFileTime())
        Get-HolderLiveness -ProcessId $PID -StartFt $earlier | Should -Be 'dead'
    }
    It 'a pid with no process is dead' {
        $none = New-FakeProcessTable @{}
        Get-HolderLiveness -ProcessId 4242 -StartFt $script:MyFt -GetProcess $none | Should -Be 'dead'
    }
    It 'a marker with no usable start time is unknown, never live or dead' {
        Get-HolderLiveness -ProcessId $PID -StartFt '' | Should -Be 'unknown'
        Get-HolderLiveness -ProcessId $PID -StartFt 'not-a-time' | Should -Be 'unknown'
    }
    It 'a process that refuses to reveal its start time is unknown' {
        $guarded = { param($id) $o = [pscustomobject]@{}; $o | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'access denied' }; $o }
        Get-HolderLiveness -ProcessId 4242 -StartFt $script:MyFt -GetProcess $guarded | Should -Be 'unknown'
    }
    It 'is unknown - not dead - when the reused start-time rule is not loaded' {
        # A fresh process that loads the state library WITHOUT Board-Work.ps1, asking about this very
        # (live) test process: the answer must be 'unknown', not 'dead' and not 'live'.
        $lib = Join-Path $PSScriptRoot '..' 'scripts' 'PluginState.ps1'
        $answer = pwsh -NoProfile -Command ". '$lib'; Get-HolderLiveness -ProcessId $PID -StartFt '$($script:MyFt)'"
        "$answer".Trim() | Should -Be 'unknown'
    }
}

Describe 'Registry readers' {
    It 'reads installed plugins, including several scopes for one key' {
        $fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Installed -Sha 'abcdef1234567')
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Installed -Scope 'project')
        $r = Get-InstalledPluginEntries -ClaudeHome $fx.Root
        $r.Ok | Should -BeTrue
        @($r.Entries).Count | Should -Be 2
        ($r.Entries | Where-Object Scope -eq 'user').Sha | Should -Be 'abcdef1234567'
        $r.Entries[0].Plugin | Should -Be 'p'; $r.Entries[0].Marketplace | Should -Be 'm'
    }
    It 'reports an unreadable installed_plugins.json as not-ok, with a reason' {
        $fx = New-Fx
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'installed_plugins.json'), '{ nope')
        $r = Get-InstalledPluginEntries -ClaudeHome $fx.Root
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'unreadable'
    }
    It 'reads marketplaces and their source kind' {
        $fx = New-Fx
        Add-FakeMarketplace $fx -Name 'gh'
        Add-FakeMarketplace $fx -Name 'dev' -Kind 'directory'
        $r = Get-KnownMarketplaces -ClaudeHome $fx.Root
        ($r.Items | Where-Object Name -eq 'dev').SourceKind | Should -Be 'directory'
        ($r.Items | Where-Object Name -eq 'gh').SourceKind | Should -Be 'github'
    }
    It 'session registry: ignores the .key files, and counts a record whose pid disagrees with its file name as unreadable' {
        $fx = New-Fx
        [void](Add-FakeSession $fx -ProcId 111 -StartFt '134344744676615681' -Name 'ok')
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'sessions' '111.abc123.key'), '{"peerToken":"x"}')
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'sessions' '222.json'), '{"pid":999,"sessionId":"s","procStart":"134344744676615681"}')
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'sessions' '333.json'), 'garbage')
        $r = Read-ClaudeSessions -ClaudeHome $fx.Root
        @($r.Sessions).Count | Should -Be 1
        $r.Sessions[0].Name | Should -Be 'ok'
        $r.Unreadable | Should -Be 2
    }
    It 'a marker is valid only with a pid that matches its file name and a start time' {
        $fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Installed)
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 10 -StartFt '134344744676615681'
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 11 -StartFt '' -RawBody '{"pid":11}'
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 12 -StartFt '' -RawBody '{"pid":99,"procStartFt":"134344744676615681"}'
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 13 -StartFt '' -RawBody 'not json'
        $m = @(Read-VersionMarkers -ClaudeHome $fx.Root)
        ($m | Where-Object Valid).Pid | Should -Be 10
        @($m | Where-Object { -not $_.Valid }).Count | Should -Be 3
    }
}

Describe 'Test-PluginShipsMcp - which fix a stale plugin needs' {
    It 'a .mcp.json at the plugin root means MCP' {
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1' -Mcp
        Test-PluginShipsMcp $d | Should -BeTrue
    }
    It 'an mcpServers entry in plugin.json means MCP' {
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1'
        [System.IO.File]::WriteAllText((Join-Path $d '.claude-plugin' 'plugin.json'), '{"name":"p","mcpServers":{"a":{"command":"a"}}}')
        Test-PluginShipsMcp $d | Should -BeTrue
    }
    It 'skills-and-hooks only means no MCP' {
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1'
        Test-PluginShipsMcp $d | Should -BeFalse
    }
    It 'a missing folder or an unreadable plugin.json is unknown (null), not "no MCP"' {
        Test-PluginShipsMcp (Join-Path $TestDrive 'absent') | Should -BeNullOrEmpty
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1'
        [System.IO.File]::WriteAllText((Join-Path $d '.claude-plugin' 'plugin.json'), '{ broken')
        Test-PluginShipsMcp $d | Should -BeNullOrEmpty
    }
}

Describe 'Get-SessionPluginState - loaded build vs installed build' {
    BeforeEach {
        $script:fx = New-Fx
        $script:ft = '134344744676615681'
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0')                      # old build
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed -Sha 'bbbbbbb')   # installed build
        [void](Add-FakeSession $fx -ProcId 111 -StartFt $ft -Name 's1')
    }
    It 'STALE: the session loaded 1.0 and 2.0 is installed' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'stale'
        $st.Stale[0].Key | Should -Be 'p@m'
        $st.Stale[0].Loaded | Should -Be '1.0'
        $st.Stale[0].Installed | Should -Be '2.0'
    }
    It 'current: the session loaded the installed build' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'current'
    }
    It 'current after a reload: markers for both the old and the new build read as up to date' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $ft
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'current'
    }
    It 'UNKNOWN is not fine: a session with no marker at all is never reported current' {
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'unknown'
    }
    It 'a marker of the same pid with a DIFFERENT start time is a recycled pid and is not attributed to the session' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt '134300000000000000'
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'unknown'
    }
    It 'a session that predates start-time records (no procStart) can never be matched: unknown' {
        [void](Add-FakeSession $fx -ProcId 222 -StartFt '' -Name 'old-format')
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 222 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions | Where-Object Pid -eq 222
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'unknown'
    }
    It 'a plugin that is no longer installed is not stale' {
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'gone' -Version '1.0')
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'gone' -Version '1.0' -ProcId 111 -StartFt $ft
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.State | Should -Be 'current'
    }
    It 'MCP plugin: a stale plugin that ships an MCP server needs a NEW session' {
        $fx2 = New-Fx
        [void](Add-FakeBuild $fx2 -Marketplace 'm' -Plugin 'srv' -Version '1.0' -Mcp)
        [void](Add-FakeBuild $fx2 -Marketplace 'm' -Plugin 'srv' -Version '2.0' -Installed -Mcp)
        [void](Add-FakeSession $fx2 -ProcId 111 -StartFt $ft)
        Add-FakeMarker $fx2 -Marketplace 'm' -Plugin 'srv' -Version '1.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx2.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx2.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx2.Root).Entries
        $st.Stale[0].NeedsNewSession | Should -BeTrue
    }
    It 'skills-only plugin: /reload-plugins is enough' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $ft
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.Stale[0].NeedsNewSession | Should -BeFalse
    }
    It 'when the MCP question cannot be answered it is unknown, and unknown asks for a new session' {
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $ft
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'cache' 'm' 'p' '1.0' '.claude-plugin' 'plugin.json'), '{ broken')
        $s = (Read-ClaudeSessions -ClaudeHome $fx.Root).Sessions[0]
        $st = Get-SessionPluginState -Session $s -Markers (Read-VersionMarkers -ClaudeHome $fx.Root) -InstalledEntries (Get-InstalledPluginEntries -ClaudeHome $fx.Root).Entries
        $st.Stale[0].NeedsNewSession | Should -BeTrue
    }
}

Describe 'Get-LiveSessionMap + Format-SessionMap' {
    BeforeEach {
        $script:fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0')
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed)
        $script:ftLive = '134344744676615681'
        $script:table = New-FakeProcessTable @{ [long]111 = $ftLive; [long]333 = $ftLive }
    }
    It 'lists an open stale session with name, folder and the plugin loaded -> installed' {
        [void](Add-FakeSession $fx -ProcId 111 -StartFt $ftLive -Name 'Sales model' -Cwd 'D:\proj\sales')
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $ftLive
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        @($map.Sessions).Count | Should -Be 1
        $map.Sessions[0].State | Should -Be 'stale'
        $text = (Format-SessionMap -Map $map | ForEach-Object Text) -join "`n"
        $text | Should -Match 'Sales model'
        $text | Should -Match 'D:\\proj\\sales'
        $text | Should -Match 'p@m: cargo 1\.0 -> instalado 2\.0'
        $text | Should -Match '/reload-plugins'
    }
    It 'NEVER prints the name, folder or id of a session that is not live' {
        $sid = Add-FakeSession $fx -ProcId 999 -StartFt $ftLive -Name 'Ghost session' -Cwd 'D:\secret\ghost'
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 999 -StartFt $ftLive
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        @($map.Sessions).Count | Should -Be 0
        $map.DeadIgnored | Should -Be 1
        $all = ((Format-SessionMap -Map $map | ForEach-Object Text) -join "`n") + ($map | ConvertTo-Json -Depth 6)
        $all | Should -Not -Match 'Ghost session'
        $all | Should -Not -Match 'secret'
        $all | Should -Not -Match $sid
    }
    It 'a recycled session pid (a later process owns the number now) is dead and never printed' {
        [void](Add-FakeSession $fx -ProcId 111 -StartFt '134300000000000000' -Name 'Recycled ghost')
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        @($map.Sessions).Count | Should -Be 0
        $map.DeadIgnored | Should -Be 1
    }
    It 'a session whose liveness cannot be confirmed is counted, not listed' {
        [void](Add-FakeSession $fx -ProcId 111 -StartFt '' -Name 'No start time')
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        @($map.Sessions).Count | Should -Be 0
        $map.UnknownLiveness | Should -Be 1
        ((Format-SessionMap -Map $map | ForEach-Object Text) -join "`n") | Should -Not -Match 'No start time'
    }
    It 'an open session with no markers is listed as SIN DATOS, and is not counted as up to date' {
        [void](Add-FakeSession $fx -ProcId 333 -StartFt $ftLive -Name 'Blind session')
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        $map.Sessions[0].State | Should -Be 'unknown'
        $lines = @(Format-SessionMap -Map $map)
        # the per-session line itself (the summary line also says "sin datos", in lower case)
        ($lines | ForEach-Object Text) -join "`n" | Should -MatchExactly 'Blind session".*SIN DATOS: no encuentro'
        ($lines | ForEach-Object Text) -join "`n" | Should -Match '0 al dia'
    }
    It 'an unreadable installed list is a failure, not "all current"' {
        [System.IO.File]::WriteAllText((Join-Path $fx.Root 'plugins' 'installed_plugins.json'), '{ nope')
        $map = Get-LiveSessionMap -ClaudeHome $fx.Root -GetProcess $table
        $map.Ok | Should -BeFalse
        ((Format-SessionMap -Map $map | ForEach-Object Text) -join "`n") | Should -Match 'No pude comprobar'
    }
}
