#Requires -Modules Pester
<#  Pester tests for Compact-PreCompactHook.ps1 - the transcript-snapshot safety net
    (epic #348).

    The hook reads stdin and copies a file, so it exposes a dot-source guard: with
    $env:ABIOS_PRECOMPACT_DOTSOURCE set it returns after defining the pure
    New-CompactSnapshotName helper. These tests exercise only that helper, with a
    FIXED clock so the name is deterministic. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Compact-PreCompactHook.ps1' | Resolve-Path
    $env:ABIOS_PRECOMPACT_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_PRECOMPACT_DOTSOURCE = ''

    $script:T0 = [datetime]'2026-07-17T10:05:09Z'
}

Describe 'New-CompactSnapshotName' {
    It 'is a colon-free UTC stamp with the trigger and .jsonl extension' {
        New-CompactSnapshotName $script:T0 'auto' | Should -BeExactly '20260717T100509Z-auto.jsonl'
    }
    It 'lowercases the trigger' {
        New-CompactSnapshotName $script:T0 'MANUAL' | Should -BeExactly '20260717T100509Z-manual.jsonl'
    }
    It 'falls back to "unknown" for a junk trigger' {
        New-CompactSnapshotName $script:T0 '' | Should -BeExactly '20260717T100509Z-unknown.jsonl'
        New-CompactSnapshotName $script:T0 'a b' | Should -BeExactly '20260717T100509Z-unknown.jsonl'
    }
    It 'never contains a colon (invalid on Windows)' {
        New-CompactSnapshotName $script:T0 'auto' | Should -Not -Match ':'
    }
}

Describe 'New-CompactMarker - a pointer, not a copy (#737)' {
    It 'records when, why, which repo, which session and where the transcript lives' {
        $m = New-CompactMarker -When $script:T0 -Trigger 'AUTO' -Repo 'D:\r\app' -SessionId 's1' -Transcript 'C:\t\s1.jsonl' -Bytes 42
        $m.at | Should -Be '2026-07-17T10:05:09Z'
        $m.trigger | Should -Be 'auto'
        $m.repo | Should -Be 'D:\r\app'
        $m.sessionId | Should -Be 's1'
        $m.transcript | Should -Be 'C:\t\s1.jsonl'
        $m.transcriptBytes | Should -Be 42
    }
}

Describe 'Compact-PreCompactHook end to end - non-ASCII working directory (#682)' {

    BeforeAll {
        # Built from code points so this file stays ASCII-clean: O-acute, n-tilde.
        $script:Odd = "IA-AUTOMATIZACI$([char]0x00D3)N-A$([char]0x00D1)O"
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ("abios-682-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force $script:Base | Out-Null
        # The marker goes to the Claude home; point the child's CLAUDE_CONFIG_DIR at a sandbox so the
        # test never writes into the real ~/.claude.
        $script:SandboxHome = Join-Path $script:Base 'claude-home'
        $script:PrevConfigDir = $env:CLAUDE_CONFIG_DIR
        $env:CLAUDE_CONFIG_DIR = $script:SandboxHome

        # Run the REAL hook as a child process, feeding the payload as UTF-8 bytes - which is what
        # Claude Code does. (Piping from PowerShell would re-encode it and hide the bug.)
        function script:RunHook {
            param([string]$Cwd, [string]$Transcript)
            $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
            foreach ($a in '-NoProfile', '-File', $script:Script.Path) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
            $psi.UseShellExecute = $false
            $p = [System.Diagnostics.Process]::Start($psi)
            try {
                $json = @{ cwd = $Cwd; transcript_path = $Transcript; trigger = 'manual' } | ConvertTo-Json -Compress
                $p.StandardInput.Write($json); $p.StandardInput.Close()
                # Read both streams concurrently, THEN wait with a bound: reading one stream to the end
                # first can deadlock on a full pipe, and a wait placed after a blocking read never times out.
                $outTask = $p.StandardOutput.ReadToEndAsync()
                $errTask = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(30000)) { throw 'the hook did not exit within 30 seconds' }
                $null = $outTask.GetAwaiter().GetResult(); $null = $errTask.GetAwaiter().GetResult()
                $p.ExitCode
            }
            finally {
                # Whatever went wrong above, never leave the child running. (Process.Kill(bool) needs
                # PowerShell 7 - as does everything else in this file, which also spawns pwsh.)
                if (-not $p.HasExited) { try { $p.Kill($true) } catch { } }
                $p.Dispose()
            }
        }
    }
    AfterAll {
        $env:CLAUDE_CONFIG_DIR = $script:PrevConfigDir
        Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'records the real repo path in the marker, and writes nothing inside the repo (#737, #682)' {
        $repo = Join-Path $script:Base $script:Odd
        New-Item -ItemType Directory -Force $repo | Out-Null
        & git -C $repo init -q 2>$null
        # If git could not initialise the repo the hook would fall back to $cwd and this test would
        # pass without ever exercising the decoding of git's output.
        $LASTEXITCODE | Should -Be 0
        $tr = Join-Path $script:Base 'transcript.jsonl'
        Set-Content -LiteralPath $tr -Value '{"a":1}'

        script:RunHook -Cwd $repo -Transcript $tr | Should -Be 0

        # The transcript is NOT copied into the repo any more: it carried the whole context window
        # (global CLAUDE.md included) into a folder one `git add -f` away from being published, and
        # it was a verbatim duplicate of a file Claude Code already keeps.
        Test-Path -LiteralPath (Join-Path $repo '.agentic-board') | Should -BeFalse
        $markers = Join-Path $script:SandboxHome 'agentic-board' 'compact-markers.jsonl'
        Test-Path -LiteralPath $markers | Should -BeTrue
        $m = @(Get-Content -LiteralPath $markers -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json })
        $m.Count | Should -Be 1
        # The non-ASCII path survives git's output decoding (#682).
        (Split-Path $m[0].repo -Leaf) | Should -BeExactly $script:Odd
        $m[0].transcript | Should -Be $tr
        $m[0].trigger | Should -Be 'manual'
        # No sibling folder that is a mis-decoding of the real one.
        @(Get-ChildItem -LiteralPath $script:Base -Directory | Where-Object { $_.Name -notin @($script:Odd, 'claude-home') }).Count | Should -Be 0
    }

    It 'never creates a directory for a cwd that does not exist' {
        # The parent exists and must stay empty: with the bug, the hook created a mis-decoded twin
        # of the ghost path here, which a Test-Path on the ghost itself would never notice.
        $sandbox = Join-Path $script:Base 'ghost-parent'
        New-Item -ItemType Directory -Force $sandbox | Out-Null
        $ghost = Join-Path $sandbox "no-existe-$([char]0x00D3)"
        $tr = Join-Path $script:Base 'transcript2.jsonl'
        Set-Content -LiteralPath $tr -Value '{"a":1}'

        script:RunHook -Cwd $ghost -Transcript $tr | Should -Be 0

        @(Get-ChildItem -LiteralPath $sandbox -Force).Count | Should -Be 0
    }
}
