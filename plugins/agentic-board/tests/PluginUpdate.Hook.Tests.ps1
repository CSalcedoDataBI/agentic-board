#Requires -Modules Pester
<#  In-session stale-plugin notice (epic #711, task #714).

    The hook decides from a FABRICATED Claude home (sessions/<pid>.json + cache markers + installed list)
    and writes its once-only state under a temp state directory. The decision function is driven directly,
    and the real script is also run as a process over real stdin (UTF-8, garbage, nothing) with HOME and
    CLAUDE_CONFIG_DIR pointed at temp folders, to prove the three things a UserPromptSubmit hook owes the
    session: it says the right thing ONCE, it is silent otherwise, and it never fails or blocks.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Hook = Join-Path $script:Scripts 'PluginStale-NoticeHook.ps1'
    . (Join-Path $script:Scripts 'PluginState.ps1')
    $env:ABIOS_PLUGINNOTICE_DOTSOURCE = '1'
    . $script:Hook
    $env:ABIOS_PLUGINNOTICE_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    function script:New-Fx { New-FakeHome -Root (Join-Path $TestDrive ("h" + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    function script:New-StateDir { $d = Join-Path $TestDrive ("s" + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $d | Out-Null; return $d }
    $script:Ft = '134344744676615681'

    # plugin p@m: 1.0 loaded by the session, 2.0 installed. Returns @{ Fx; Sid; Payload }.
    function script:New-StaleScenario {
        param([switch]$Mcp, [string]$SessionId = 'sess-1')
        $fx = New-Fx
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Mcp:$Mcp)
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed -Mcp:$Mcp)
        [void](Add-FakeSession $fx -ProcId 111 -StartFt $script:Ft -SessionId $SessionId -Name 'me')
        Add-FakeMarker $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $script:Ft
        return @{ Fx = $fx; Payload = (@{ session_id = $SessionId; prompt = 'hello'; hook_event_name = 'UserPromptSubmit' } | ConvertTo-Json -Compress) }
    }

    # Run the real hook script over real stdin. Returns @{ ExitCode; Stdout; Stderr }.
    function script:Invoke-HookProcess {
        param([string]$Stdin, [string]$ClaudeHome, [string]$HomeDir, [switch]$NoStdin)
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in '-NoProfile', '-File', $script:Hook) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.Environment['CLAUDE_CONFIG_DIR'] = $ClaudeHome
        $psi.Environment['HOME'] = $HomeDir
        $psi.Environment['USERPROFILE'] = $HomeDir
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $NoStdin) {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Stdin)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $p.StandardInput.Close()
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { try { $p.Kill($true) } catch { }; return @{ ExitCode = -999; Stdout = ''; Stderr = 'timeout' } }
        $p.WaitForExit()
        return @{ ExitCode = $p.ExitCode; Stdout = $so.Result.Trim(); Stderr = $se.Result.Trim() }
    }
}

Describe 'Invoke-StaleNotice - the decision' {
    It 'tells the session, in plain words, that a plugin it loaded was updated and to type /reload-plugins' {
        $sc = New-StaleScenario
        $note = Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir (New-StateDir)
        $note | Should -Match 'Se actualizo el plugin "p" a la version 2\.0'
        $note | Should -Match 'sigue con la 1\.0'
        $note | Should -Match '/reload-plugins'
        $note | Should -Not -Match 'sesion nueva'
    }
    It 'a plugin that ships an MCP server says "open a new session", not /reload-plugins' {
        $sc = New-StaleScenario -Mcp
        $note = Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir (New-StateDir)
        $note | Should -Match 'abre una sesion nueva'
        $note | Should -Not -Match '/reload-plugins'
    }
    It 'says it ONCE per (session, plugin, new build): the second prompt is silent' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -Not -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
    }
    It 'a NEWER build later is a new notice; the older one stays acknowledged' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        [void](Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd)
        [void](Add-FakeBuild $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '3.0')
        Set-FakeInstalledBuild $sc.Fx -Key 'p@m' -Version '3.0'
        $note = Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd
        $note | Should -Match 'version 3\.0'
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
    }
    It 'another session has its own once-only record' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        [void](Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd)
        [void](Add-FakeSession $sc.Fx -ProcId 222 -StartFt $script:Ft -SessionId 'sess-2')
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 222 -StartFt $script:Ft
        $other = @{ session_id = 'sess-2' } | ConvertTo-Json -Compress
        (Invoke-StaleNotice -StdinText $other -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -Match '/reload-plugins'
    }
    It 'is silent when nothing is stale' {
        $sc = New-StaleScenario
        # the session reloaded: it now holds the installed build too
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 111 -StartFt $script:Ft
        $sd = New-StateDir
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        # nothing was announced: the once-only record for this session is empty
        $s = (Get-Content -LiteralPath (Join-Path $sd 'plugin-notices.json') -Raw | ConvertFrom-Json).sessions
        @($s.PSObject.Properties).Count | Should -Be 0
    }
    It 'is silent when the session cannot be identified or has no record of what it loaded' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        (Invoke-StaleNotice -StdinText '{"session_id":"not-a-session"}' -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText '{}' -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText 'garbage {' -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText '' -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
        [void](Add-FakeSession $sc.Fx -ProcId 333 -StartFt $script:Ft -SessionId 'blind')
        (Invoke-StaleNotice -StdinText '{"session_id":"blind"}' -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -BeNullOrEmpty
    }
    It 'does not attribute a marker of a recycled pid (different start time) to the session' {
        $sc = New-StaleScenario
        [void](Add-FakeSession $sc.Fx -ProcId 444 -StartFt $script:Ft -SessionId 'sess-4')
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 444 -StartFt '134300000000000000'
        (Invoke-StaleNotice -StdinText '{"session_id":"sess-4"}' -ClaudeHome $sc.Fx.Root -StateDir (New-StateDir)) | Should -BeNullOrEmpty
    }
    It 'a damaged state file reads as "nothing shown yet" and is rewritten; it never throws' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        [System.IO.File]::WriteAllText((Join-Path $sd 'plugin-notices.json'), '{ broken')
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd) | Should -Match '/reload-plugins'
        (Get-Content -LiteralPath (Join-Path $sd 'plugin-notices.json') -Raw | ConvertFrom-Json).sessions.'sess-1' | Should -Not -BeNullOrEmpty
    }
    It 'keeps the state file small: sessions that are no longer in the registry are dropped' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        $old = @{ sessions = @{ 'long-gone-session' = @{ 'x@y@1' = '2026-01-01T00:00:00' } } } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $sd 'plugin-notices.json'), $old)
        [void](Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd)
        $s = (Get-Content -LiteralPath (Join-Path $sd 'plugin-notices.json') -Raw | ConvertFrom-Json).sessions
        $s.PSObject.Properties.Name | Should -Not -Contain 'long-gone-session'
        $s.PSObject.Properties.Name | Should -Contain 'sess-1'
    }
    It 'respects its time budget: out of budget it stays silent and records nothing' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -BudgetMs -1) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $sd 'plugin-notices.json') | Should -BeFalse
    }
    It 'COST: while the installed list is unchanged the session is not re-examined, and is again after the recheck interval' {
        $sc = New-StaleScenario
        $inuse = Join-Path $sc.Fx.Root 'plugins' 'cache' 'm' 'p'
        # first check: the session holds the INSTALLED build (2.0) -> nothing to say
        Remove-Item -LiteralPath (Join-Path $inuse '1.0' '.in_use' '111')
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -ProcId 111 -StartFt $script:Ft
        $sd = New-StateDir
        $t0 = [datetime]::UtcNow
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -NowUtc $t0) | Should -BeNullOrEmpty
        # behind the hook's back the session now looks stale - installed_plugins.json was NOT touched
        Remove-Item -LiteralPath (Join-Path $inuse '2.0' '.in_use' '111')
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $script:Ft
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -NowUtc $t0.AddMinutes(5)) | Should -BeNullOrEmpty
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -NowUtc $t0.AddMinutes(31)) | Should -Match 'reload-plugins'
    }
    It 'COST: an update (the installed list changing) is noticed on the very next prompt' {
        $sc = New-StaleScenario
        $sd = New-StateDir
        $t0 = [datetime]::UtcNow
        [void](Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -NowUtc $t0)
        [void](Add-FakeBuild $sc.Fx -Marketplace 'm' -Plugin 'p' -Version '3.0')
        Set-FakeInstalledBuild $sc.Fx -Key 'p@m' -Version '3.0'
        (Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir $sd -NowUtc $t0.AddMinutes(1)) | Should -Match 'version 3\.0'
    }
    It 'several stale plugins arrive as ONE message, one line each' {
        $sc = New-StaleScenario
        [void](Add-FakeBuild $sc.Fx -Marketplace 'm' -Plugin 'q' -Version '1.0')
        [void](Add-FakeBuild $sc.Fx -Marketplace 'm' -Plugin 'q' -Version '1.1' -Installed)
        Add-FakeMarker $sc.Fx -Marketplace 'm' -Plugin 'q' -Version '1.0' -ProcId 111 -StartFt $script:Ft
        $note = Invoke-StaleNotice -StdinText $sc.Payload -ClaudeHome $sc.Fx.Root -StateDir (New-StateDir)
        @($note -split "`n").Count | Should -Be 2
        $note | Should -Match '"p"'
        $note | Should -Match '"q"'
    }
}

Describe 'the real hook script over real stdin' {
    It 'prints the notice as a systemMessage once, then stays silent; always exit 0' {
        $sc = New-StaleScenario
        $home_ = Join-Path $TestDrive 'realhome'
        New-Item -ItemType Directory -Force -Path $home_ | Out-Null
        $first = Invoke-HookProcess -Stdin $sc.Payload -ClaudeHome $sc.Fx.Root -HomeDir $home_
        $first.ExitCode | Should -Be 0
        ($first.Stdout | ConvertFrom-Json).systemMessage | Should -Match '/reload-plugins'
        Test-Path -LiteralPath (Join-Path $home_ '.agentic-board' 'plugin-notices.json') | Should -BeTrue
        $second = Invoke-HookProcess -Stdin $sc.Payload -ClaudeHome $sc.Fx.Root -HomeDir $home_
        $second.ExitCode | Should -Be 0
        $second.Stdout | Should -BeNullOrEmpty
    }
    It 'reads stdin as UTF-8: a prompt with accents and non-Latin text does not break the payload' {
        $sc = New-StaleScenario -SessionId 'sess-utf8'
        $payload = (@{ session_id = 'sess-utf8'; prompt = "actualiza el modelo de ventas - caf$([char]0xE9) $([char]0x00F1) $([char]0x65E5)$([char]0x672C)" } | ConvertTo-Json -Compress)
        $home_ = Join-Path $TestDrive 'utf8home'
        New-Item -ItemType Directory -Force -Path $home_ | Out-Null
        $r = Invoke-HookProcess -Stdin $payload -ClaudeHome $sc.Fx.Root -HomeDir $home_
        $r.ExitCode | Should -Be 0
        ($r.Stdout | ConvertFrom-Json).systemMessage | Should -Match 'Se actualizo el plugin'
    }
    It 'garbage, empty and missing stdin all exit 0 with no output and no error text' {
        $sc = New-StaleScenario
        $home_ = Join-Path $TestDrive 'quiethome'
        New-Item -ItemType Directory -Force -Path $home_ | Out-Null
        foreach ($in in 'not json at all {{{', '', '{"session_id":') {
            $r = Invoke-HookProcess -Stdin $in -ClaudeHome $sc.Fx.Root -HomeDir $home_
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $r.Stderr | Should -BeNullOrEmpty
        }
    }
    It 'a Claude home that does not exist exits 0, silently' {
        $home_ = Join-Path $TestDrive 'nohome'
        New-Item -ItemType Directory -Force -Path $home_ | Out-Null
        $r = Invoke-HookProcess -Stdin '{"session_id":"x"}' -ClaudeHome (Join-Path $TestDrive 'does-not-exist') -HomeDir $home_
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
    }
}

Describe 'hooks.json wiring' {
    BeforeAll { $script:Hooks = Get-Content (Join-Path $PSScriptRoot '..' 'hooks' 'hooks.json' | Resolve-Path) -Raw | ConvertFrom-Json }
    It 'registers the notice on UserPromptSubmit (the only event that fires after an update, in a session that is already open)' {
        $cmds = @($script:Hooks.hooks.UserPromptSubmit | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        ($cmds -join ' ') | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'gives the hook a timeout of at most 10 seconds' {
        $h = @($script:Hooks.hooks.UserPromptSubmit | ForEach-Object { $_.hooks } | Where-Object { $_.command -match 'PluginStale-NoticeHook' })[0]
        [int]$h.timeout | Should -BeGreaterThan 0
        [int]$h.timeout | Should -BeLessOrEqual 10
    }
    It 'the script the wiring names exists' {
        Test-Path -LiteralPath $script:Hook | Should -BeTrue
    }
    It 'the existing hooks are still wired' {
        $script:Hooks.hooks.SessionStart | Should -Not -BeNullOrEmpty
        $script:Hooks.hooks.PreToolUse | Should -Not -BeNullOrEmpty
        $script:Hooks.hooks.PreCompact | Should -Not -BeNullOrEmpty
    }
}
