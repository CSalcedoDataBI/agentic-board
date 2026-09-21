# PluginUpdate.TestKit.ps1 - fabricates a ~/.claude tree for the plugin-update tests (epic #711).
# Dot-sourced by the PluginUpdate*.Tests.ps1 files; it is not a test file itself.
#
# Nothing here touches the real Claude home: every function takes the fabricated root, and the tree holds
# installed_plugins.json, known_marketplaces.json, sessions/<pid>.json and
# cache/<marketplace>/<plugin>/<version>/ (with .claude-plugin/plugin.json and .in_use/<pid> markers).

function New-FakeHome {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'plugins' 'cache') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'sessions') | Out-Null
    return [pscustomobject]@{
        Root = $Root
        Installed = [System.Collections.Generic.List[object]]::new()
        Marketplaces = [System.Collections.Generic.List[object]]::new()
    }
}

function Write-FakeRegistries {
    param($Fx)
    $plugins = [ordered]@{}
    foreach ($e in $Fx.Installed) {
        if (-not $plugins.Contains($e.Key)) { $plugins[$e.Key] = @() }
        $entry = [ordered]@{ scope = $e.Scope; installPath = $e.InstallPath; version = $e.Version }
        if ($e.Sha) { $entry.gitCommitSha = $e.Sha }
        $plugins[$e.Key] += , $entry
    }
    $json = [ordered]@{ version = 2; plugins = $plugins } | ConvertTo-Json -Depth 8
    $ipath = Join-Path $Fx.Root 'plugins' 'installed_plugins.json'
    [System.IO.File]::WriteAllText($ipath, $json)
    # Every rewrite gets a distinct last-write time (the in-session hook watches it as the "an update
    # happened" signal, and two writes inside one clock tick would otherwise look identical).
    $script:FakeRegistrySeq = 1 + [int]$script:FakeRegistrySeq
    (Get-Item -LiteralPath $ipath).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-3600 + $script:FakeRegistrySeq)

    $mk = [ordered]@{}
    foreach ($m in $Fx.Marketplaces) {
        $src = if ($m.Kind -eq 'directory') { [ordered]@{ source = 'directory'; path = $m.Location } }
               else { [ordered]@{ source = 'github'; repo = "fake/$($m.Name)" } }
        $rec = [ordered]@{ source = $src; installLocation = $m.Location; lastUpdated = '2026-09-01T00:00:00.000Z' }
        $mk[$m.Name] = $rec
    }
    [System.IO.File]::WriteAllText((Join-Path $Fx.Root 'plugins' 'known_marketplaces.json'), ($mk | ConvertTo-Json -Depth 8))
}

function Add-FakeMarketplace {
    param($Fx, [string]$Name, [string]$Kind = 'github')
    $loc = Join-Path $Fx.Root 'plugins' 'marketplaces' $Name
    New-Item -ItemType Directory -Force -Path $loc | Out-Null
    $Fx.Marketplaces.Add([pscustomobject]@{ Name = $Name; Kind = $Kind; Location = $loc })
    Write-FakeRegistries $Fx
}

# One cached build. -Installed also records it in installed_plugins.json. -AgeHours backdates the
# directory so the cleanup grace period does not protect it. -Mcp gives it a .mcp.json.
function Add-FakeBuild {
    param(
        $Fx, [string]$Marketplace, [string]$Plugin, [string]$Version,
        [switch]$Installed, [string]$Scope = 'user', [string]$Sha = '', [switch]$Mcp, [int]$AgeHours = 48
    )
    $dir = Join-Path $Fx.Root 'plugins' 'cache' $Marketplace $Plugin $Version
    New-Item -ItemType Directory -Force -Path (Join-Path $dir '.claude-plugin') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir '.claude-plugin' 'plugin.json'), (@{ name = $Plugin; version = $Version } | ConvertTo-Json))
    if ($Mcp) { [System.IO.File]::WriteAllText((Join-Path $dir '.mcp.json'), '{"mcpServers":{"x":{"command":"x"}}}') }
    if ($Installed) {
        $Fx.Installed.Add([pscustomobject]@{ Key = "$Plugin@$Marketplace"; Scope = $Scope; InstallPath = $dir; Version = $Version; Sha = $Sha })
        Write-FakeRegistries $Fx
    }
    $old = (Get-Date).AddHours(-$AgeHours)
    foreach ($p in @(Get-ChildItem -LiteralPath $dir -Recurse -Force)) { $p.LastWriteTime = $old }
    (Get-Item -LiteralPath $dir).LastWriteTime = $old
    return $dir
}

# Pretend a plugin was updated: the same key now points at a different build.
function Set-FakeInstalledBuild {
    param($Fx, [string]$Key, [string]$Version, [string]$Sha = '')
    $old = @($Fx.Installed | Where-Object { $_.Key -eq $Key -and $_.Scope -eq 'user' })[0]
    $parts = $Key -split '@'
    $newPath = Join-Path $Fx.Root 'plugins' 'cache' $parts[1] $parts[0] $Version
    $old.InstallPath = $newPath; $old.Version = $Version; $old.Sha = $Sha
    Write-FakeRegistries $Fx
}

function Add-FakeMarker {
    param($Fx, [string]$Marketplace, [string]$Plugin, [string]$Version, [long]$ProcId, [string]$StartFt, [string]$RawBody = '')
    $iu = Join-Path $Fx.Root 'plugins' 'cache' $Marketplace $Plugin $Version '.in_use'
    New-Item -ItemType Directory -Force -Path $iu | Out-Null
    $body = if ($RawBody) { $RawBody } else { "{`"pid`":$ProcId,`"procStartFt`":`"$StartFt`"}" }
    [System.IO.File]::WriteAllText((Join-Path $iu "$ProcId"), $body)
    # Creating .in_use touches its parent: backdate both so the cleanup grace period does not apply.
    $old = (Get-Date).AddHours(-48)
    (Get-Item -LiteralPath $iu).LastWriteTime = $old
    (Get-Item -LiteralPath (Split-Path $iu -Parent)).LastWriteTime = $old
}

function Add-FakeSession {
    param($Fx, [long]$ProcId, [string]$StartFt, [string]$SessionId = ([guid]::NewGuid().ToString()), [string]$Name = 'session', [string]$Cwd = 'C:\work')
    $rec = [ordered]@{ pid = $ProcId; sessionId = $SessionId; cwd = $Cwd; procStart = $StartFt; version = '2.1.275'; status = 'idle'; name = $Name }
    [System.IO.File]::WriteAllText((Join-Path $Fx.Root 'sessions' "$ProcId.json"), ($rec | ConvertTo-Json))
    return $SessionId
}

# FILETIME text of this very test process: a real, live process with a real start time.
function Get-MyFileTimeText { return "$((Get-Process -Id $PID).StartTime.ToFileTime())" }

# A process table for -GetProcess: pid -> FILETIME text. Any other pid does not exist.
function New-FakeProcessTable {
    param([hashtable]$Table)
    return { param($id)
        if ($Table.ContainsKey([long]$id)) { [pscustomobject]@{ StartTime = [datetime]::FromFileTime([long]$Table[[long]$id]) } }
    }.GetNewClosure()
}
