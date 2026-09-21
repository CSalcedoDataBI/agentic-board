#Requires -Modules Pester
<#  PluginStale-NoticePreCheck.cmd - the cheap gate in front of the stale-plugin notice (epic #711, #714).

    The hook runs before EVERY prompt of EVERY session and a pwsh start alone costs about 2 s, so a cmd shim
    (the Brake-PreCheck.cmd idea, #572) answers the common case. These tests drive the REAL .cmd over real
    stdin with fabricated ~/.claude and state folders. "pwsh was not started" is proved, not assumed: for
    most cases a fake pwsh.cmd is put first on PATH and records its arguments, so a run either left a line
    in its log or it did not. The end-to-end cases use the real pwsh and the real hook.

    The shim may only skip work when the stamp provably matches the last conclusive check of the same
    session; anything else must reach pwsh. An invalid session id must stay silent.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Shim = Join-Path $script:Scripts 'PluginStale-NoticePreCheck.cmd'
    $script:Hook = Join-Path $script:Scripts 'PluginStale-NoticeHook.ps1'
    . (Join-Path $script:Scripts 'PluginState.ps1')
    $env:ABIOS_PLUGINNOTICE_DOTSOURCE = '1'
    . $script:Hook
    $env:ABIOS_PLUGINNOTICE_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    $script:Id = 'fc250d38-1384-4486-beae-91ef341119df'
    $script:Ft = '134344744676615681'

    # A fabricated world: Claude home with an installed list, a home dir for the state, a fake pwsh on PATH.
    function script:New-ShimWorld {
        $root = Join-Path $TestDrive ("w" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $fx = New-FakeHome -Root (Join-Path $root 'claude')
        $home_ = Join-Path $root 'home'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ '.agentic-board') | Out-Null
        $bin = Join-Path $root 'bin'
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $log = Join-Path $root 'pwsh-ran.txt'
        [System.IO.File]::WriteAllText((Join-Path $bin 'pwsh.cmd'), "@echo off`r`necho %* >> `"$log`"`r`nexit /b 0`r`n")
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0')
        [void](Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '2.0' -Installed)
        return @{ Root = $root; Fx = $fx; Home = $home_; Bin = $bin; Log = $log
                  StampDir = (Join-Path $home_ '.agentic-board' 'plugin-check'); StateDir = (Join-Path $home_ '.agentic-board') }
    }

    # Run the real shim. -FakePwsh puts the recording pwsh.cmd first on PATH. Returns ExitCode/Stdout/Stderr/Ms/Ran.
    function script:Invoke-Shim {
        param($World, [string]$Stdin, [switch]$FakePwsh)
        if (Test-Path -LiteralPath $World.Log) { Remove-Item -LiteralPath $World.Log -Force }
        $psi = [System.Diagnostics.ProcessStartInfo]::new('cmd.exe')
        $psi.Arguments = '/d /c ""' + $script:Shim + '""'
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        if ($FakePwsh) { $psi.Environment['PATH'] = "$($World.Bin);" + $env:PATH }
        $psi.Environment['USERPROFILE'] = $World.Home; $psi.Environment['HOME'] = $World.Home
        $psi.Environment['CLAUDE_CONFIG_DIR'] = $World.Fx.Root
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = [System.Diagnostics.Process]::Start($psi)
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Stdin)
        try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close() } catch { }
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { try { $p.Kill($true) } catch { }; return @{ ExitCode = -999; Stdout = ''; Stderr = 'timeout'; Ms = 120000; Ran = $null } }
        $p.WaitForExit()
        $ms = $sw.ElapsedMilliseconds
        $ran = if (Test-Path -LiteralPath $World.Log) { (Get-Content -LiteralPath $World.Log -Raw).Trim() } else { $null }
        return @{ ExitCode = $p.ExitCode; Stdout = $so.Result.Trim(); Stderr = $se.Result.Trim(); Ms = $ms; Ran = $ran }
    }

    function script:New-Payload([string]$Id = $script:Id, [string]$Prompt = 'hello') {
        return (@{ session_id = $Id; transcript_path = 'C:\t.jsonl'; cwd = 'C:\w'; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt } | ConvertTo-Json -Compress)
    }
    # Put the real stamp in place, exactly as a conclusive hook run would.
    function script:Set-Stamp($World, [string]$Id = $script:Id) {
        $info = Get-InstalledInfo $World.Fx.Root
        Write-ShimStamp -StateDir $World.StateDir -SessionId $Id -Installed $info
    }
}

Describe 'hooks.json routes UserPromptSubmit through the shim' {
    BeforeAll { $script:Hooks = Get-Content (Join-Path $PSScriptRoot '..' 'hooks' 'hooks.json' | Resolve-Path) -Raw | ConvertFrom-Json }
    It 'calls the .cmd shim through cmd, not pwsh directly, and keeps the 10 s timeout' {
        $h = @($script:Hooks.hooks.UserPromptSubmit | ForEach-Object { $_.hooks })[0]
        $h.command | Should -Match 'cmd /d /c'
        $h.command | Should -Match 'PluginStale-NoticePreCheck\.cmd'
        $h.command | Should -Not -Match 'PluginStale-NoticeHook\.ps1'
        [int]$h.timeout | Should -BeLessOrEqual 10
        [int]$h.timeout | Should -BeGreaterThan 0
    }
    It 'the shim file has CRLF line endings (cmd.exe can mis-parse labels in LF-only files; .gitattributes keeps it so)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Shim)
        $lf = @(0..($bytes.Length - 1) | Where-Object { $bytes[$_] -eq 10 })
        $bareLf = @($lf | Where-Object { $_ -eq 0 -or $bytes[$_ - 1] -ne 13 })
        $lf.Count | Should -BeGreaterThan 20
        $bareLf.Count | Should -Be 0
    }
    It 'the shim names the hook it starts, and passes the id, never the payload' {
        $body = Get-Content $script:Shim -Raw
        $body | Should -Match 'PluginStale-NoticeHook\.ps1'
        $body | Should -Match '-SessionId !ID!'
    }
}

Describe 'the shim takes only a validated session id from the first line' -Skip:(-not $IsWindows) {
    It 'a hostile prompt full of shell metacharacters is never executed and never reaches pwsh: only the -SessionId argument does' {
        $w = New-ShimWorld
        $prompt = 'a & echo pwned > "' + $w.Root + '\pwned.txt" | b < c > d ^ e %PATH% !VAR! "q" ''s'' ) ('
        $r = Invoke-Shim $w (New-Payload -Prompt $prompt) -FakePwsh
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
        $r.Stderr | Should -BeNullOrEmpty
        $r.Ran | Should -Match ([regex]::Escape("-SessionId $($script:Id)"))
        $r.Ran | Should -Not -Match 'pwned|echo|PATH'
        Test-Path -LiteralPath (Join-Path $w.Root 'pwned.txt') | Should -BeFalse
    }
    It 'a prompt that comes BEFORE the session id, and says session_id itself, still cannot inject' {
        $w = New-ShimWorld
        $line = '{"prompt":"x & echo pwned > ' + $w.Root + '\pwned.txt","session_id":"' + $script:Id + '"}'
        $r = Invoke-Shim $w $line -FakePwsh
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.Root 'pwned.txt') | Should -BeFalse
        if ($r.Ran) { $r.Ran | Should -Not -Match 'pwned' }
    }
    It 'a pretty-printed "session_id": "..." (with a space) is still read' {
        $w = New-ShimWorld
        $r = Invoke-Shim $w ('{"session_id": "' + $script:Id + '"}') -FakePwsh
        $r.Ran | Should -Match ([regex]::Escape("-SessionId $($script:Id)"))
    }
    It 'only the FIRST line is read: a second line cannot supply or change the id' {
        $w = New-ShimWorld
        $r = Invoke-Shim $w ('{"prompt":"first line only"' + "`r`n" + '{"session_id":"' + $script:Id + '"}') -FakePwsh
        $r.Ran | Should -BeNullOrEmpty
    }
    It 'a payload truncated AFTER the id still works; one truncated INSIDE the id stays silent' {
        $w = New-ShimWorld
        (Invoke-Shim $w ('{"session_id":"' + $script:Id) -FakePwsh).Ran | Should -Match ([regex]::Escape("-SessionId $($script:Id)"))
        $r = Invoke-Shim $w ('{"session_id":"' + $script:Id.Substring(0, 20)) -FakePwsh
        $r.Ran | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 0
    }
    It 'missing, empty, short, non-hex, over-long and path-like ids: exit 0, silent, pwsh NOT started' {
        $w = New-ShimWorld
        $cases = @(
            '', 'not json at all', '{}', '{"session_id":""}', '{"session_id":"abc"}',
            ('{"session_idX' + $script:Id + '"}'),            # no colon after the key: not a session_id field
            ('{"session_id":"' + $script:Id + '/escape"}'),   # a valid 36-char prefix followed by a path character
            ('{"session_id":"' + $script:Id + '&calc"}'),
            ('{"session_id":"' + $script:Id + '."}'),
            ('{"session_id":"' + $script:Id.Replace('a', 'g') + '"}'),
            ('{"session_id":"' + $script:Id + '0"}'),
            '{"session_id":"..\..\evil"}', '{"session_id":"../../evil-and-very-long-so-it-has-36-chars"}',
            ('{"session_id":"' + ('a' * 35) + '/"}'),
            '{"session_id":"C:\Windows\System32\config\SAM0000000"}'
        )
        foreach ($in in $cases) {
            $r = Invoke-Shim $w $in -FakePwsh
            $r.ExitCode | Should -Be 0 -Because "input: $in"
            $r.Stdout | Should -BeNullOrEmpty -Because "input: $in"
            $r.Stderr | Should -BeNullOrEmpty -Because "input: $in"
            $r.Ran | Should -BeNullOrEmpty -Because "pwsh must not start for: $in"
        }
    }
    It 'an id with path characters cannot make the hook write outside the stamp folder' {
        $w = New-ShimWorld
        $info = Get-InstalledInfo $w.Fx.Root
        foreach ($bad in '..\..\escape', '../escape', 'C:\escape', 'a b', "x`0y") {
            Write-ShimStamp -StateDir $w.StateDir -SessionId $bad -Installed $info
        }
        Test-Path -LiteralPath (Join-Path $w.StateDir 'plugin-check') | Should -BeFalse -Because 'not even the folder is created for an invalid id'
        @(Get-ChildItem -LiteralPath $w.Root -Recurse -Filter 'installed_plugins.json' -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike (Join-Path $w.Fx.Root '*') }).Count | Should -Be 0
    }
}

Describe 'the stamp decides whether pwsh runs' -Skip:(-not $IsWindows) {
    It 'no stamp yet: pwsh runs' {
        $w = New-ShimWorld
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'stamp equal to the installed list: pwsh is NOT started (proved by the recording pwsh) and stdout is empty' {
        $w = New-ShimWorld
        Set-Stamp $w
        $r = Invoke-Shim $w (New-Payload) -FakePwsh
        $r.ExitCode | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
        $r.Stdout | Should -BeNullOrEmpty
    }
    It 'the installed list rewritten AFTER the stamp (an update): pwsh runs' {
        $w = New-ShimWorld
        Set-Stamp $w
        Add-FakeBuild $w.Fx -Marketplace 'm' -Plugin 'p' -Version '3.0' | Out-Null
        Set-FakeInstalledBuild $w.Fx -Key 'p@m' -Version '3.0'
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'same size, DIFFERENT content (a version bump of equal length) runs pwsh: the comparison is by content' {
        $w = New-ShimWorld
        Set-Stamp $w
        $ip = Join-Path $w.Fx.Root 'plugins' 'installed_plugins.json'
        $len = (Get-Item $ip).Length
        [System.IO.File]::WriteAllText($ip, ([System.IO.File]::ReadAllText($ip)).Replace('2.0', '3.0'))
        (Get-Item $ip).Length | Should -Be $len
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'only the file TIME changed (identical bytes): nothing to re-check, pwsh is not started' {
        $w = New-ShimWorld
        Set-Stamp $w
        $ip = Join-Path $w.Fx.Root 'plugins' 'installed_plugins.json'
        (Get-Item $ip).LastWriteTimeUtc = [datetime]::UtcNow
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -BeNullOrEmpty
    }
    It 'an older content restored (different bytes) runs pwsh' {
        $w = New-ShimWorld
        Set-Stamp $w
        $ip = Join-Path $w.Fx.Root 'plugins' 'installed_plugins.json'
        $t = (Get-Item $ip).LastWriteTimeUtc
        [System.IO.File]::AppendAllText($ip, ' ')
        (Get-Item $ip).LastWriteTimeUtc = $t.AddHours(-5)
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'the stamp holds the list as the check read it, so a rewrite during the check still makes the next prompt run pwsh' {
        $w = New-ShimWorld
        $atStart = Get-InstalledInfo $w.Fx.Root                      # what the hook read when it began
        Add-FakeBuild $w.Fx -Marketplace 'm' -Plugin 'p' -Version '3.0' | Out-Null
        Set-FakeInstalledBuild $w.Fx -Key 'p@m' -Version '3.0'         # an update lands while it works
        Write-ShimStamp -StateDir $w.StateDir -SessionId $script:Id -Installed $atStart
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'the stamp of ANOTHER session does not let this one skip' {
        $w = New-ShimWorld
        Set-Stamp $w 'aaaaaaaa-1111-2222-3333-444444444444'
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'an unreadable or garbage stamp, a missing stamp folder or a missing installed list: pwsh runs' {
        $w = New-ShimWorld
        Set-Stamp $w
        [System.IO.File]::WriteAllText((Join-Path $w.StampDir $script:Id 'installed_plugins.json'), 'not the same bytes')
        (Invoke-Shim $w (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
        $w2 = New-ShimWorld
        (Invoke-Shim $w2 (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
        $w3 = New-ShimWorld
        Set-Stamp $w3
        Remove-Item -LiteralPath (Join-Path $w3.Fx.Root 'plugins' 'installed_plugins.json') -Force
        (Invoke-Shim $w3 (New-Payload) -FakePwsh).Ran | Should -Match 'PluginStale-NoticeHook\.ps1'
    }
    It 'is cheap: a skipped prompt returns well inside a pwsh start (generous CI bound)' {
        $w = New-ShimWorld
        Set-Stamp $w
        $r = Invoke-Shim $w (New-Payload) -FakePwsh
        $r.Ran | Should -BeNullOrEmpty
        # The point is "no interpreter spawn" (about 2 s here), not a benchmark: 3 s leaves room for a busy CI box.
        $r.Ms | Should -BeLessThan 3000
    }
}

Describe 'end to end: real shim, real hook, real pwsh' -Skip:(-not $IsWindows) {
    BeforeAll {
        # A stale session: it loaded p 1.0, 2.0 is installed. Ids are UUID-shaped, as the shim requires.
        function script:New-E2E {
            $w = New-ShimWorld
            [void](Add-FakeSession $w.Fx -ProcId 111 -StartFt $script:Ft -SessionId $script:Id -Name 'me')
            Add-FakeMarker $w.Fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $script:Ft
            return $w
        }
    }
    It 'stale session: the notice reaches stdout unchanged, then a stamp is written and the next prompt does not start pwsh' {
        $w = New-E2E
        $r1 = Invoke-Shim $w (New-Payload)
        $r1.ExitCode | Should -Be 0
        ($r1.Stdout | ConvertFrom-Json).systemMessage | Should -Match 'reload-plugins'
        $stamp = Join-Path $w.StampDir $script:Id 'installed_plugins.json'
        Test-Path -LiteralPath $stamp | Should -BeTrue
        # Proof pwsh is not started the second time: the notice state file is deleted; a pwsh run would recreate it.
        $state = Join-Path $w.StateDir 'plugin-notices.json'
        Remove-Item -LiteralPath $state -Force
        $r2 = Invoke-Shim $w (New-Payload)
        $r2.ExitCode | Should -Be 0
        $r2.Stdout | Should -BeNullOrEmpty
        Test-Path -LiteralPath $state | Should -BeFalse -Because 'the hook did not run'
    }
    It 'the stamp is a byte-for-byte copy of the installed list as the check read it' {
        $w = New-E2E
        [void](Invoke-Shim $w (New-Payload))
        $stamp = Join-Path $w.StampDir $script:Id 'installed_plugins.json'
        $ip = Join-Path $w.Fx.Root 'plugins' 'installed_plugins.json'
        [System.IO.File]::ReadAllBytes($stamp) | Should -Be ([System.IO.File]::ReadAllBytes($ip))
    }
    It 'an INCONCLUSIVE check (the session has no marker yet) writes NO stamp, so the next prompt still reaches pwsh' {
        $w = New-E2E
        Remove-Item -LiteralPath (Join-Path $w.Fx.Root 'plugins' 'cache' 'm' 'p' '1.0' '.in_use' '111') -Force
        $r = Invoke-Shim $w (New-Payload)
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $w.StampDir $script:Id) | Should -BeFalse
        # the marker turns up (the first prompt raced ahead of it); the JSON state's own 5 minute memo is cleared
        # so the hook may look again, and what matters here is that the SHIM lets it through
        Add-FakeMarker $w.Fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -ProcId 111 -StartFt $script:Ft
        Remove-Item -LiteralPath (Join-Path $w.StateDir 'plugin-notices.json') -Force
        $r2 = Invoke-Shim $w (New-Payload)
        ($r2.Stdout | ConvertFrom-Json).systemMessage | Should -Match 'reload-plugins'
    }
    It 'a session that is not in the registry yet is inconclusive too: no stamp' {
        $w = New-E2E
        $other = 'bbbbbbbb-1111-2222-3333-444444444444'
        $r = Invoke-Shim $w (New-Payload -Id $other)
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $w.StampDir $other) | Should -BeFalse
    }
    It 'after an update the very next prompt reaches pwsh again and the newer build is announced' {
        $w = New-E2E
        [void](Invoke-Shim $w (New-Payload))
        Add-FakeBuild $w.Fx -Marketplace 'm' -Plugin 'p' -Version '3.0' | Out-Null
        Set-FakeInstalledBuild $w.Fx -Key 'p@m' -Version '3.0'
        $r = Invoke-Shim $w (New-Payload)
        ($r.Stdout | ConvertFrom-Json).systemMessage | Should -Match 'version 3\.0'
    }
    It 'stamps of sessions that are gone from the registry are removed on the next conclusive check' {
        $w = New-E2E
        $ghost = 'cccccccc-1111-2222-3333-444444444444'
        Set-Stamp $w $ghost
        Test-Path -LiteralPath (Join-Path $w.StampDir $ghost) | Should -BeTrue
        [void](Invoke-Shim $w (New-Payload))
        Test-Path -LiteralPath (Join-Path $w.StampDir $ghost) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $w.StampDir $script:Id) | Should -BeTrue
    }
    It 'a hostile prompt through the whole chain: exit 0, a valid notice, nothing executed' {
        $w = New-E2E
        $prompt = 'x & echo pwned > "' + $w.Root + '\pwned.txt" | y < z > q ^ %PATH% !V! "quoted"'
        $r = Invoke-Shim $w (New-Payload -Prompt $prompt)
        $r.ExitCode | Should -Be 0
        ($r.Stdout | ConvertFrom-Json).systemMessage | Should -Match 'reload-plugins'
        Test-Path -LiteralPath (Join-Path $w.Root 'pwned.txt') | Should -BeFalse
    }
}
