#Requires -Modules Pester
<#  agentic-board is Markdown only; agentic-board-tools holds every script and hook (#768).

    The plugin directory accepts, from an organization that is not Verified, only Markdown, text,
    JSON, YAML and images, and no hooks of any type. So the listed plugin (plugins/agentic-board)
    carries skills, commands, its manifest and its icon, and plugins/agentic-board-tools - installed
    from this repo's own marketplace, never submitted - carries the scripts, presets and hooks.
    These tests pin what makes that split safe:
      1. the listed plugin holds only accepted file types and no hooks;
      2. the tools plugin wires every hook to a script it ships, and publishes its folder for the
         skills (Tools-Root.sh);
      3. no skill or command still points a script at the Markdown plugin's own folder;
      4. a brake-armed launch refuses to start when agentic-board-tools is missing or disabled;
      5. the few scripts that read the Markdown plugin find it (BoardPluginRoot.ps1).  #>

BeforeAll {
    $script:Repo  = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Main  = Join-Path $script:Repo 'plugins' 'agentic-board'
    $script:Tools = Join-Path $script:Repo 'plugins' 'agentic-board-tools'
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . (Join-Path $script:Tools 'scripts' 'Brake-Guard.ps1')
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = ''
    . (Join-Path $script:Tools 'scripts' 'BoardPluginRoot.ps1')

    function script:New-FakeConfig([string]$Path, [hashtable]$Plugins) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Path 'plugins') | Out-Null
        Set-Content -LiteralPath (Join-Path $Path 'plugins' 'installed_plugins.json') -Value (@{ version = 2; plugins = $Plugins } | ConvertTo-Json -Depth 6)
        return $Path
    }
    function script:New-FakeBoard([string]$Path, [string]$Name = 'agentic-board') {
        New-Item -ItemType Directory -Force -Path (Join-Path $Path '.claude-plugin') | Out-Null
        Set-Content -LiteralPath (Join-Path $Path '.claude-plugin' 'plugin.json') -Value (@{ name = $Name } | ConvertTo-Json)
        return $Path
    }
    $script:Shipped = @(git -C $script:Repo ls-files -- 'plugins/agentic-board' | Where-Object { $_ })
}

Describe 'the listed plugin is Markdown only (#768)' {
    It 'every shipped file is a type the directory accepts' {
        $script:Shipped.Count | Should -BeGreaterThan 20
        $bad = @($script:Shipped | Where-Object { $_ -notmatch '\.(md|txt|json|ya?ml|png|jpe?g|gif|webp|ico)$' })
        $bad | Should -BeNullOrEmpty
    }
    It 'nothing in it starts with #! and nothing is a .claude folder or a second manifest' {
        foreach ($f in $script:Shipped) {
            $f | Should -Not -Match '(^|/)\.claude/'
            if ($f -match '\.claude-plugin/' ) { $f | Should -Match '^plugins/agentic-board/\.claude-plugin/' }
            $head = [IO.File]::ReadAllBytes((Join-Path $script:Repo $f)) | Select-Object -First 2
            ([char]$head[0] + [char]$head[1]) | Should -Not -Be '#!' -Because $f
        }
    }
    It 'has no hooks folder and no hooks key in plugin.json' {
        Test-Path -LiteralPath (Join-Path $script:Main 'hooks') | Should -BeFalse
        (Get-Content (Join-Path $script:Main '.claude-plugin' 'plugin.json') -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'hooks'
    }
    It 'stays under 512 files' {
        $script:Shipped.Count | Should -BeLessThan 512
    }
    It 'no longer ships the experto pieces (they belong to AI-Factory)' {
        Test-Path -LiteralPath (Join-Path $script:Main 'commands' 'expert.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Main 'skills' 'board-expert') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $script:Tools 'scripts') -Filter 'Expert*.ps1').Count | Should -Be 0
    }
}

Describe 'skills and commands run the tools plugin''s scripts' {
    It 'no Markdown file points a script at the Markdown plugin''s own folder' {
        foreach ($f in @($script:Shipped | Where-Object { $_ -match '\.md$' })) {
            $t = Get-Content -LiteralPath (Join-Path $script:Repo $f) -Raw
            $t | Should -Not -Match ([regex]::Escape('${CLAUDE_PLUGIN_ROOT}/scripts/')) -Because $f
            $t | Should -Not -Match ([regex]::Escape('${CLAUDE_PLUGIN_ROOT}/presets/')) -Because $f
        }
    }
    It 'every <tools>/scripts/X a Markdown file names exists in the tools plugin' {
        $names = foreach ($f in @($script:Shipped | Where-Object { $_ -match '\.md$' })) {
            [regex]::Matches((Get-Content -LiteralPath (Join-Path $script:Repo $f) -Raw), '<tools>/scripts/([A-Za-z][A-Za-z0-9.-]+\.(?:ps1|sh))') | ForEach-Object { $_.Groups[1].Value }
        }
        @($names | Select-Object -Unique).Count | Should -BeGreaterThan 10
        foreach ($n in ($names | Select-Object -Unique)) { Test-Path -LiteralPath (Join-Path $script:Tools 'scripts' $n) | Should -BeTrue -Because $n }
    }
    It 'every file that says <tools> is an entry with the preamble, or a reference of a skill that has it' {
        foreach ($f in @($script:Shipped | Where-Object { $_ -match '\.md$' })) {
            $t = Get-Content -LiteralPath (Join-Path $script:Repo $f) -Raw
            if ($t -notmatch '<tools>/') { continue }
            if ($f -match '/commands/[^/]+\.md$|/skills/[^/]+/SKILL\.md$') {
                $t | Should -Match 'companion plugin \*\*agentic-board-tools\*\*' -Because $f
            } else {
                $skill = [regex]::Match($f, '^(plugins/agentic-board/skills/[^/]+)/').Groups[1].Value
                $skill | Should -Not -BeNullOrEmpty -Because $f
                Get-Content -LiteralPath (Join-Path $script:Repo $skill 'SKILL.md') -Raw | Should -Match 'agentic-board-tools' -Because "$f is loaded by $skill"
            }
        }
    }
}

Describe 'the tools plugin wires the hooks and publishes its folder' {
    It 'is named agentic-board-tools, versioned with agentic-board, and listed in the marketplace' {
        $pj = Get-Content (Join-Path $script:Tools '.claude-plugin' 'plugin.json') -Raw | ConvertFrom-Json
        $pj.name | Should -BeExactly 'agentic-board-tools'
        $pj.version | Should -Be (Get-Content (Join-Path $script:Main '.claude-plugin' 'plugin.json') -Raw | ConvertFrom-Json).version
        $mk = Get-Content (Join-Path $script:Repo '.claude-plugin' 'marketplace.json') -Raw | ConvertFrom-Json
        @($mk.plugins | Where-Object name -eq 'agentic-board-tools')[0].source.path | Should -Be 'plugins/agentic-board-tools'
    }
    It 'every hook command names a script the tools plugin ships' {
        $hooks = Get-Content (Join-Path $script:Tools 'hooks' 'hooks.json') -Raw | ConvertFrom-Json
        $cmds = @($hooks.hooks.PSObject.Properties | ForEach-Object { $_.Value } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        $cmds.Count | Should -Be 7
        foreach ($c in $cmds) {
            $file = [regex]::Match($c, 'scripts/([A-Za-z.-]+\.(ps1|sh))').Groups[1].Value
            $file | Should -Not -BeNullOrEmpty -Because $c
            Test-Path -LiteralPath (Join-Path $script:Tools 'scripts' $file) | Should -BeTrue -Because $c
        }
    }
    It 'Tools-Root.sh writes the folder to ~/.agentic-board/tools-root and to CLAUDE_ENV_FILE' {
        $home_ = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Force -Path $home_ | Out-Null
        $envFile = Join-Path $TestDrive 'session.env'
        $psi = [System.Diagnostics.ProcessStartInfo]::new('sh')
        $psi.ArgumentList.Add((Join-Path $script:Tools 'scripts' 'Tools-Root.sh'))
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.Environment['HOME'] = $home_; $psi.Environment['USERPROFILE'] = $home_
        $psi.Environment['CLAUDE_PLUGIN_ROOT'] = "C:/fake/it's/agentic-board-tools/0.45.0"
        $psi.Environment['CLAUDE_ENV_FILE'] = $envFile
        $p = [System.Diagnostics.Process]::Start($psi); $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
        $p.ExitCode | Should -Be 0
        $out | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $home_ '.agentic-board' 'tools-root') -Raw).Trim() | Should -Be "C:/fake/it's/agentic-board-tools/0.45.0"
        (Get-Content -LiteralPath $envFile -Raw).Trim() | Should -Be "export AGENTIC_BOARD_TOOLS='C:/fake/it'\''s/agentic-board-tools/0.45.0'"
    }
    It 'Tools-Root.sh is LF-only' {
        @([IO.File]::ReadAllBytes((Join-Path $script:Tools 'scripts' 'Tools-Root.sh')) | Where-Object { $_ -eq 13 }).Count | Should -Be 0
    }
}

Describe 'BoardPluginRoot finds the Markdown plugin' {
    It 'takes the sibling checkout first' {
        Get-BoardPluginRoot -ToolsRoot $script:Tools -ClaudeHome (Join-Path $TestDrive 'none') | Should -Be (Resolve-Path $script:Main).Path
    }
    It 'else the newest user-scope install, refusing a folder that is not agentic-board' {
        $old = New-FakeBoard (Join-Path $TestDrive 'r1' 'old')
        $new = New-FakeBoard (Join-Path $TestDrive 'r1' 'new')
        $wrong = New-FakeBoard (Join-Path $TestDrive 'r1' 'wrong') -Name 'other'
        $cfg = New-FakeConfig (Join-Path $TestDrive 'r1' 'cfg') @{
            'agentic-board@agentic-board' = @(
                @{ scope = 'user'; installPath = $old; lastUpdated = '2026-01-01T00:00:00Z' },
                @{ scope = 'user'; installPath = $wrong; lastUpdated = '2026-12-01T00:00:00Z' },
                @{ scope = 'user'; installPath = $new; lastUpdated = '2026-06-01T00:00:00Z' }) }
        $isolated = Join-Path $TestDrive 'r1' 'cache' 'agentic-board-tools' '0.45.0'
        Get-BoardPluginRoot -ToolsRoot $isolated -ClaudeHome $cfg -Cwd $TestDrive | Should -Be $new
    }
    It 'returns empty when nothing qualifies' {
        Get-BoardPluginRoot -ToolsRoot (Join-Path $TestDrive 'nowhere' 'x') -ClaudeHome (Join-Path $TestDrive 'none') | Should -Be ''
    }
}

Describe 'Test-BrakeHookInstalled: a brake-armed launch needs agentic-board-tools' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ('wt-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
        $script:Cfg = Join-Path $TestDrive ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    }
    It 'no installed list -> not ok, with the install command' {
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'plugin install agentic-board-tools@agentic-board'
    }
    It 'only agentic-board installed -> not ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
    }
    It 'user-scope tools plugin -> ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-tools@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeTrue
        $r.Key | Should -Be 'agentic-board-tools@agentic-board'
    }
    It 'a project install for another folder does not count; one containing the worktree does' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-tools@m' = @(@{ scope = 'project'; projectPath = (Join-Path $TestDrive 'other'); installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
        New-FakeConfig $script:Cfg @{ 'agentic-board-tools@m' = @(@{ scope = 'local'; projectPath = $TestDrive; installPath = 'x' }) } | Out-Null
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeTrue
    }
    It 'disabled in the user or the project settings -> not ok' {
        New-FakeConfig $script:Cfg @{ 'agentic-board-tools@agentic-board' = @(@{ scope = 'user'; installPath = 'x' }) } | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Cfg 'settings.json') -Value '{"enabledPlugins":{"agentic-board-tools@agentic-board":false}}'
        $r = Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'disabled'
        Set-Content -LiteralPath (Join-Path $script:Cfg 'settings.json') -Value '{"enabledPlugins":{"agentic-board-tools@agentic-board":true}}'
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeTrue
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Work '.claude') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Work '.claude' 'settings.local.json') -Value '{"enabledPlugins":{"agentic-board-tools@agentic-board":false}}'
        (Test-BrakeHookInstalled -WorkPath $script:Work -ClaudeHome $script:Cfg).Ok | Should -BeFalse
    }
}

Describe 'Start-WorktreeSession refuses a brake-armed launch without agentic-board-tools (#768)' {
    BeforeAll {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:Tools 'scripts' 'Board-Work.ps1')
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
    It 'missing tools plugin: no marker, no session, $null' {
        Mock Test-BrakeHookInstalled { @{ Ok = $false; Key = ''; Reason = 'the brake hook plugin agentic-board-tools is not installed' } }
        Start-WorktreeSession -IssueNum 768 -Repo 'o/r' -Branch 'issue-768-x' -WorkPath $script:Work -StopAtPR 6>$null | Should -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:Work '.agentic-board' 'brake-armed.json') | Should -BeFalse
    }
    It 'tools plugin present: armed and launched' {
        Mock Test-BrakeHookInstalled { @{ Ok = $true; Key = 'agentic-board-tools@agentic-board'; Reason = '' } }
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
