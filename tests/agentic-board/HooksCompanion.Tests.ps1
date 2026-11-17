#Requires -Modules Pester
<#  The hooks live in the companion plugin agentic-board-hooks (#768).

    agentic-board is listed in the plugin directory, where a plugin whose hooks start pwsh or sh is
    held for review on every version. So agentic-board ships no hooks; agentic-board-hooks wires
    them and its dispatcher, Invoke-BoardHook.ps1, runs agentic-board's own hook scripts. These
    tests pin the three things that make that safe:
      1. the listed plugin really has no hooks, and every wired hook reaches a real script;
      2. the dispatcher finds the right agentic-board and, for the brake only, fails CLOSED;
      3. a brake-armed launch refuses to start when the companion is missing or disabled.  #>

BeforeAll {
    $script:Repo     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Main     = Join-Path $script:Repo 'plugins' 'agentic-board'
    $script:Companion = Join-Path $script:Repo 'plugins' 'agentic-board-hooks'
    $script:Dispatch = Join-Path $script:Companion 'scripts' 'Invoke-BoardHook.ps1'
    $env:ABIOS_HOOKDISPATCH_DOTSOURCE = '1'
    . $script:Dispatch
    $env:ABIOS_HOOKDISPATCH_DOTSOURCE = ''
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . (Join-Path $script:Main 'scripts' 'Brake-Guard.ps1')
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = ''

    # A fake agentic-board install: plugin.json with $Name and every hook script, empty.
    function script:New-FakeBoard([string]$Path, [string]$Name = 'agentic-board') {
        New-Item -ItemType Directory -Force -Path (Join-Path $Path '.claude-plugin'), (Join-Path $Path 'scripts') | Out-Null
        Set-Content -LiteralPath (Join-Path $Path '.claude-plugin' 'plugin.json') -Value (@{ name = $Name } | ConvertTo-Json)
        foreach ($s in $script:HookTargets.Values) { Set-Content -LiteralPath (Join-Path $Path 'scripts' $s) -Value 'exit 0' }
        return $Path
    }
    # A Claude config folder whose installed_plugins.json holds $Plugins (key -> array of entries).
    function script:New-FakeConfig([string]$Path, [hashtable]$Plugins) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Path 'plugins') | Out-Null
        Set-Content -LiteralPath (Join-Path $Path 'plugins' 'installed_plugins.json') -Value (@{ version = 2; plugins = $Plugins } | ConvertTo-Json -Depth 6)
        return $Path
    }
    # Run the dispatcher as Claude Code does, from a copy in a folder with no sibling agentic-board.
    function script:Invoke-Dispatch([string]$Hook, [string]$ConfigDir, [string]$Stdin = '{}') {
        $iso = Join-Path $TestDrive ('iso-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) 'agentic-board-hooks' 'scripts'
        New-Item -ItemType Directory -Force -Path $iso | Out-Null
        Copy-Item -LiteralPath $script:Dispatch -Destination $iso
        $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
        foreach ($a in @('-NoProfile', '-File', (Join-Path $iso 'Invoke-BoardHook.ps1'), '-Hook', $Hook)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false; $psi.WorkingDirectory = $TestDrive
        $psi.Environment['CLAUDE_CONFIG_DIR'] = $ConfigDir
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($Stdin); $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return @{ ExitCode = $p.ExitCode; Stdout = $out.Trim() }
    }
}

Describe 'the listed plugin ships no hooks; the companion wires them all (#768)' {
    It 'agentic-board has no hooks folder and no hooks key in plugin.json' {
        Test-Path -LiteralPath (Join-Path $script:Main 'hooks') | Should -BeFalse
        $pj = Get-Content (Join-Path $script:Main '.claude-plugin' 'plugin.json') -Raw | ConvertFrom-Json
        $pj.PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }
    It 'the companion is a valid plugin named agentic-board-hooks, listed in the marketplace' {
        (Get-Content (Join-Path $script:Companion '.claude-plugin' 'plugin.json') -Raw | ConvertFrom-Json).name | Should -BeExactly 'agentic-board-hooks'
        $mk = Get-Content (Join-Path $script:Repo '.claude-plugin' 'marketplace.json') -Raw | ConvertFrom-Json
        $entry = @($mk.plugins | Where-Object name -eq 'agentic-board-hooks')
        $entry.Count | Should -Be 1
        $entry[0].source.path | Should -Be 'plugins/agentic-board-hooks'
    }
    It 'every hook command names a script the companion ships, and every -Hook maps to a real agentic-board script' {
        $hooks = Get-Content (Join-Path $script:Companion 'hooks' 'hooks.json') -Raw | ConvertFrom-Json
        $cmds = @($hooks.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        $cmds.Count | Should -Be 6
        foreach ($c in $cmds) {
            $c | Should -Match ([regex]::Escape('${CLAUDE_PLUGIN_ROOT}/scripts/'))
            $file = [regex]::Match($c, 'scripts/([A-Za-z.-]+\.(ps1|sh))').Groups[1].Value
            Test-Path -LiteralPath (Join-Path $script:Companion 'scripts' $file) | Should -BeTrue -Because $c
            if ($c -match '-Hook (\w+)') { $script:HookTargets.Keys | Should -Contain $Matches[1] }
        }
        foreach ($s in $script:HookTargets.Values) { Test-Path -LiteralPath (Join-Path $script:Main 'scripts' $s) | Should -BeTrue -Because $s }
        (Get-Content (Join-Path $script:Companion 'scripts' 'PluginStale-NoticePreCheck.sh') -Raw) | Should -Match 'Invoke-BoardHook\.ps1" -Hook PluginStale -SessionId'
    }
}

Describe 'Invoke-BoardHook finds the installed agentic-board' {
    It 'takes a user-scope install, newest first, and skips a project install of another folder' {
        $old = New-FakeBoard (Join-Path $TestDrive 'f1' 'old')
        $new = New-FakeBoard (Join-Path $TestDrive 'f1' 'new')
        $other = New-FakeBoard (Join-Path $TestDrive 'f1' 'other')
        $cfg = New-FakeConfig (Join-Path $TestDrive 'f1' 'cfg') @{
            'agentic-board@agentic-board' = @(
                @{ scope = 'user'; installPath = $old; lastUpdated = '2026-01-01T00:00:00Z' },
                @{ scope = 'user'; installPath = $new; lastUpdated = '2026-06-01T00:00:00Z' },
                @{ scope = 'project'; projectPath = (Join-Path $TestDrive 'elsewhere'); installPath = $other; lastUpdated = '2026-09-01T00:00:00Z' })
            'agentic-board-hooks@agentic-board' = @(@{ scope = 'user'; installPath = $other; lastUpdated = '2026-10-01T00:00:00Z' })
        }
        Find-AgenticBoardRoot -ScriptName 'Brake-PreToolUseHook.ps1' -ConfigDir $cfg -Cwd $TestDrive -SelfRoot '' | Should -Be $new
    }
    It 'takes a project install whose project contains the working directory' {
        $proj = Join-Path $TestDrive 'f2' 'repo'
        $inst = New-FakeBoard (Join-Path $TestDrive 'f2' 'inst')
        $cfg = New-FakeConfig (Join-Path $TestDrive 'f2' 'cfg') @{
            'agentic-board@x' = @(@{ scope = 'local'; projectPath = $proj; installPath = $inst; lastUpdated = '2026-06-01T00:00:00Z' }) }
        Find-AgenticBoardRoot -ScriptName 'Welcome-SessionStartHook.ps1' -ConfigDir $cfg -Cwd (Join-Path $proj 'sub') -SelfRoot '' | Should -Be $inst
    }
    It 'refuses a folder whose plugin.json is not agentic-board, then falls back to the sibling checkout' {
        $fake = New-FakeBoard (Join-Path $TestDrive 'f3' 'fake') -Name 'not-the-board'
        $cfg = New-FakeConfig (Join-Path $TestDrive 'f3' 'cfg') @{ 'agentic-board@m' = @(@{ scope = 'user'; installPath = $fake }) }
        Find-AgenticBoardRoot -ScriptName 'Brake-PreToolUseHook.ps1' -ConfigDir $cfg -Cwd $TestDrive -SelfRoot '' | Should -Be ''
        Find-AgenticBoardRoot -ScriptName 'Brake-PreToolUseHook.ps1' -ConfigDir $cfg -Cwd $TestDrive -SelfRoot $script:Companion | Should -Be $script:Main
    }
}

Describe 'Invoke-BoardHook fail direction' {
    It 'the brake DENIES when agentic-board cannot be found' {
        $r = Invoke-Dispatch -Hook 'Brake' -ConfigDir (Join-Path $TestDrive 'no-config')
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match '"permissionDecision":"deny"'
    }
    It 'an advisory hook stays silent when agentic-board cannot be found' {
        $r = Invoke-Dispatch -Hook 'Welcome' -ConfigDir (Join-Path $TestDrive 'no-config') -Stdin '{"source":"startup"}'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
    }
    It 'an unknown hook name denies for nothing and prints nothing' {
        $r = Invoke-Dispatch -Hook 'Nope' -ConfigDir (Join-Path $TestDrive 'no-config')
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -BeNullOrEmpty
    }
    It 'runs the found plugin''s script and passes its exit code through' {
        $inst = Join-Path $TestDrive 'pass' 'inst'
        New-FakeBoard $inst | Out-Null
        Set-Content -LiteralPath (Join-Path $inst 'scripts' 'Compact-PreCompactHook.ps1') -Value "Write-Output ('got:' + [Console]::In.ReadToEnd()); exit 3"
        $cfg = New-FakeConfig (Join-Path $TestDrive 'pass' 'cfg') @{ 'agentic-board@m' = @(@{ scope = 'user'; installPath = $inst }) }
        $r = Invoke-Dispatch -Hook 'Compact' -ConfigDir $cfg -Stdin 'payload-768'
        $r.ExitCode | Should -Be 3
        $r.Stdout | Should -Be 'got:payload-768'
    }
}

Describe 'Test-BrakeHookInstalled: a brake-armed launch needs the companion' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ('wt-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
        $script:Cfg = Join-Path $TestDrive ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    }
    It 'no installed list -> not ok, with the install command' {
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'plugin install agentic-board-hooks@agentic-board'
    }
    It 'only agentic-board installed -> not ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
    }
    It 'user-scope companion -> ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-hooks@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeTrue
        $r.Key | Should -Be 'agentic-board-hooks@agentic-board'
    }
    It 'a project install for another folder does not count; one containing the worktree does' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-hooks@m' = @(@{ scope = 'project'; projectPath = (Join-Path $TestDrive 'other'); installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
        New-FakeConfig $script:Cfg @{ 'agentic-board-hooks@m' = @(@{ scope = 'local'; projectPath = $TestDrive; installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeTrue
    }
    It 'disabled in the user or the project settings -> not ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-hooks@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Cfg 'settings.json') -Value '{"enabledPlugins":{"agentic-board-hooks@agentic-board":false}}'
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'disabled'
        Set-Content -LiteralPath (Join-Path $script:Cfg 'settings.json') -Value '{"enabledPlugins":{"agentic-board-hooks@agentic-board":true}}'
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeTrue
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Work '.claude') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Work '.claude' 'settings.local.json') -Value '{"enabledPlugins":{"agentic-board-hooks@agentic-board":false}}'
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
    }
    It 'the launcher asks it before arming a claude session, and the refusal path is the brake''s own' {
        $launch = Get-Content (Join-Path $script:Main 'scripts' 'BoardWork.Launch.ps1') -Raw
        $gate = $launch.IndexOf('Test-BrakeHookInstalled -WorkPath $WorkPath')
        $arm  = $launch.IndexOf('$state = Set-BrakeArmedState')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeLessThan $arm
        $launch | Should -Match ([regex]::Escape("if (`$armIntent -and `$Cli -eq 'claude')"))
    }
}

Describe 'Start-WorktreeSession refuses a brake-armed launch without the companion (#768)' {
    BeforeAll {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:Main 'scripts' 'Board-Work.ps1')
        $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    }
    BeforeEach {
        $script:State = Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:State | Out-Null
        $script:Work = Join-Path $TestDrive ('launch-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
        Mock Get-AbiosStateDir { $script:State }
        Mock Get-AbiosDir { $script:State }
        Mock Start-Process { $null }
    }
    It 'missing companion: no marker, no session, $null' {
        Mock Test-BrakeHookInstalled { @{ Ok = $false; Key = ''; Reason = 'the brake hook plugin agentic-board-hooks is not installed' } }
        Start-WorktreeSession -IssueNum 768 -Repo 'o/r' -Branch 'issue-768-x' -WorkPath $script:Work -StopAtPR 6>$null | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:Work '.agentic-board' 'brake-armed.json') | Should -BeFalse
    }
    It 'companion present: armed and launched' {
        Mock Test-BrakeHookInstalled { @{ Ok = $true; Key = 'agentic-board-hooks@agentic-board'; Reason = '' } }
        $null = Start-WorktreeSession -IssueNum 768 -Repo 'o/r' -Branch 'issue-768-x' -WorkPath $script:Work -StopAtPR 6>$null
        Should -Invoke Start-Process -Times 1 -Exactly
        Test-Path -LiteralPath (Join-Path $script:Work '.agentic-board' 'brake-armed.json') | Should -BeTrue
    }
    It 'an unarmed launch never asks' {
        Mock Test-BrakeHookInstalled { throw 'must not be called' }
        $null = Start-WorktreeSession -IssueNum 768 -Repo 'o/r' -Branch 'issue-768-x' -WorkPath $script:Work 6>$null
        Should -Invoke Start-Process -Times 1 -Exactly
    }
}
