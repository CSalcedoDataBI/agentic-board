#Requires -Modules Pester
<#  Every hooks.json command line, launched the way Claude Code launches it (#812).

    Claude Code puts the plugin root into the command text and runs it with `bash -c` (Git Bash on
    Windows, a POSIX shell elsewhere). 0.44.0 called its shims as `cmd /d /c "<root>/scripts/x.cmd"`:
    with a forward-slash root such as C:/Users/<name>/..., cmd.exe read "/<first letter of the user
    folder>" as a switch, every PreToolUse and UserPromptSubmit hook errored, and the brake never ran
    (it failed open). The unit tests drove the shims directly, so they never saw the launcher.

    These copy the companion plugin under a folder whose name starts with C (Users/Csample/...), so
    the forward-slash form of the root carries a "/C" segment, and run each command line through the
    same shell, with that root written forward-slash and backslash. A hermetic HOME and Claude config
    keep the hooks from touching the machine running the tests.  #>

BeforeAll {
    . (Join-Path $PSScriptRoot 'PosixShell.TestKit.ps1'); Use-PosixShell
    $script:OnWindows = $IsWindows -or $env:OS -eq 'Windows_NT'

    # The shell Claude Code uses for hooks: Git Bash's bash on Windows, sh elsewhere.
    $sh = (Get-Command sh -ErrorAction Stop).Source
    $bash = Join-Path (Split-Path $sh -Parent) ($(if ($script:OnWindows) { 'bash.exe' } else { 'bash' }))
    $script:Shell = if (Test-Path -LiteralPath $bash) { $bash } else { $sh }

    $src = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board-tools' | Resolve-Path
    $script:Base = Join-Path $TestDrive 'Users' 'Csample'
    $script:PluginCopy = Join-Path $script:Base 'plugins' 'agentic-board-tools'
    New-Item -ItemType Directory -Path $script:PluginCopy -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $script:PluginCopy -Recurse -Force

    $hooks = (Get-Content (Join-Path $script:PluginCopy 'hooks' 'hooks.json') -Raw | ConvertFrom-Json).hooks
    $script:Lines = foreach ($ev in $hooks.PSObject.Properties) {
        foreach ($group in $ev.Value) {
            foreach ($h in $group.hooks) { [pscustomobject]@{ Event = $ev.Name; Matcher = "$($group.matcher)"; Command = $h.command } }
        }
    }

    # The root as Claude Code may write it. Forward-slash is the form that broke 0.44.0.
    $script:Roots = if ($script:OnWindows) {
        @($script:PluginCopy.Replace('\', '/'), $script:PluginCopy)
    } else { @($script:PluginCopy) }

    $script:HookHome = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Path $script:HookHome -Force | Out-Null
    $script:Clean = Join-Path $TestDrive 'clean-cwd'
    New-Item -ItemType Directory -Path $script:Clean -Force | Out-Null
    $script:Armed = Join-Path $TestDrive 'armed-cwd'
    New-Item -ItemType Directory -Path (Join-Path $script:Armed '.agentic-board') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:Armed '.agentic-board' 'brake-armed.json') -Encoding UTF8 `
        -Value '{"issue":5,"irreversible":["merge"],"endToEnd":false}'

    # Runs one hook command line as Claude Code does: root substituted into the text, `bash -c`,
    # payload on stdin, in the given working directory. Returns exit code, stdout and stderr.
    function script:Invoke-HookLine {
        param([string]$Command, [string]$Root, [string]$Payload, [string]$Cwd)
        $line = $Command.Replace('${CLAUDE_PLUGIN_ROOT}', $Root)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Shell)
        $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($line)
        $psi.WorkingDirectory = $Cwd
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.Environment['CLAUDE_PLUGIN_ROOT'] = $Root
        $psi.Environment['HOME'] = $script:HookHome
        $psi.Environment['USERPROFILE'] = $script:HookHome
        $psi.Environment['CLAUDE_CONFIG_DIR'] = Join-Path $script:HookHome '.claude'
        $psi.Environment.Remove('CLAUDE_ENV_FILE') | Out-Null
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $p.StandardInput.Write($Payload); $p.StandardInput.Close()
        if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "hook line timed out: $line" }
        [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result.Trim(); Err = $errTask.Result.Trim() }
    }

    function script:PayloadFor {
        param([string]$Event, [string]$Cwd, [string]$Tool = 'Bash', [string]$ToolCommand = 'echo hi')
        # A fixed, obviously fake session id in UUID shape (the shim accepts only that shape).
        $sid = (('0' * 8), '0000', '4000', '8000', ('0' * 9 + '812')) -join '-'
        $p = [ordered]@{ session_id = $sid; hook_event_name = $Event; cwd = $Cwd }
        switch ($Event) {
            'SessionStart'     { $p.source = 'startup' }
            'UserPromptSubmit' { $p.prompt = 'hello' }
            'PreCompact'       { $p.trigger = 'manual' }
            'PreToolUse'       { $p.tool_name = $Tool; $p.tool_input = @{ command = $ToolCommand } }
        }
        $p | ConvertTo-Json -Depth 5 -Compress
    }
}

Describe 'hooks.json command lines run from Claude Code with a C:/Users/(name) root (#812)' {
    It 'no hook goes through cmd.exe or a .cmd shim' {
        $script:Lines.Count | Should -BeGreaterThan 0
        foreach ($l in $script:Lines) {
            $l.Command | Should -Not -Match '(?i)(^|[;&|\s])cmd(\.exe)?\s'
            $l.Command | Should -Not -Match '(?i)\.(cmd|bat)\b'
        }
    }

    It 'the fixture reproduces the 0.44.0 failure: cmd /d /c with the forward-slash root never runs the shim' -Skip:(-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        $probe = Join-Path $script:PluginCopy 'scripts' 'Probe-812.cmd'
        Set-Content -LiteralPath $probe -Encoding ASCII -Value @('@echo off', 'echo PROBE-RAN')
        try {
            $r = Invoke-HookLine -Command 'cmd /d /c "${CLAUDE_PLUGIN_ROOT}/scripts/Probe-812.cmd"' `
                -Root $script:Roots[0] -Payload '{}' -Cwd $script:Clean
            "$($r.Out)" | Should -Not -Match 'PROBE-RAN'
        } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }

    It 'every line exits 0 with no error output, for each way of writing the root' {
        foreach ($root in $script:Roots) {
            foreach ($l in $script:Lines) {
                $r = Invoke-HookLine -Command $l.Command -Root $root -Payload (PayloadFor $l.Event $script:Clean) -Cwd $script:Clean
                $because = "$($l.Event) [$($l.Matcher)] with root '$root': $($r.Err)"
                $r.Code | Should -Be 0 -Because $because
                $r.Err | Should -BeNullOrEmpty -Because $because
            }
        }
    }

    It 'the PreToolUse line reaches the real brake and DENIES a merge in an armed run, for Bash and PowerShell' {
        $pre = $script:Lines | Where-Object Event -eq 'PreToolUse'
        $pre | Should -Not -BeNullOrEmpty
        foreach ($root in $script:Roots) {
            foreach ($tool in 'Bash', 'PowerShell') {
                $r = Invoke-HookLine -Command $pre[0].Command -Root $root `
                    -Payload (PayloadFor 'PreToolUse' $script:Armed -Tool $tool -ToolCommand 'gh pr merge 5') -Cwd $script:Armed
                $because = "$tool with root '$root': $($r.Err)"
                $r.Code | Should -Be 0 -Because $because
                $r.Out | Should -Match '"permissionDecision":\s*"deny"' -Because $because
                $r.Out | Should -Match 'BRAKE' -Because $because
            }
        }
    }

    It 'in an armed run, a brake hook that errors is a refusal, not a silent pass (fail closed)' {
        $pre = ($script:Lines | Where-Object Event -eq 'PreToolUse')[0]
        $hook = Join-Path $script:PluginCopy 'scripts' 'Brake-PreToolUseHook.ps1'
        $saved = Get-Content -LiteralPath $hook -Raw
        try {
            foreach ($broken in @('throw "boom"; exit 0', 'exit 3', $null)) {
                if ($null -eq $broken) { Remove-Item -LiteralPath $hook -Force } else { Set-Content -LiteralPath $hook -Value $broken -Encoding UTF8 }
                $r = Invoke-HookLine -Command $pre.Command -Root $script:Roots[0] `
                    -Payload (PayloadFor 'PreToolUse' $script:Armed -ToolCommand 'gh pr merge 5') -Cwd $script:Armed
                $because = "broken hook '$broken': $($r.Out) $($r.Err)"
                $r.Code | Should -Be 0 -Because $because
                $r.Out | Should -Match '"permissionDecision":"deny"' -Because $because
                $r.Out | Should -Match 'failed to run' -Because $because
            }
        } finally { Set-Content -LiteralPath $hook -Value $saved -Encoding UTF8 -NoNewline }
    }

    It 'outside an armed run the PreToolUse line stays silent, even with a broken brake hook' {
        $pre = ($script:Lines | Where-Object Event -eq 'PreToolUse')[0]
        $hook = Join-Path $script:PluginCopy 'scripts' 'Brake-PreToolUseHook.ps1'
        $saved = Get-Content -LiteralPath $hook -Raw
        try {
            Set-Content -LiteralPath $hook -Value 'exit 3' -Encoding UTF8
            $r = Invoke-HookLine -Command $pre.Command -Root $script:Roots[0] `
                -Payload (PayloadFor 'PreToolUse' $script:Clean -ToolCommand 'gh pr merge 5') -Cwd $script:Clean
            $r.Code | Should -Be 0
            $r.Out | Should -BeNullOrEmpty
        } finally { Set-Content -LiteralPath $hook -Value $saved -Encoding UTF8 -NoNewline }
    }
}
