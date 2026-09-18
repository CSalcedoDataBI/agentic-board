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

Describe 'Compact-PreCompactHook end to end - non-ASCII working directory (#682)' {

    BeforeAll {
        # Built from code points so this file stays ASCII-clean: O-acute, n-tilde.
        $script:Odd = "IA-AUTOMATIZACI$([char]0x00D3)N-A$([char]0x00D1)O"
        $script:Base = Join-Path ([IO.Path]::GetTempPath()) ("abios-682-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force $script:Base | Out-Null

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
            $json = @{ cwd = $Cwd; transcript_path = $Transcript; trigger = 'manual' } | ConvertTo-Json -Compress
            $p.StandardInput.Write($json); $p.StandardInput.Close()
            $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
            $p.WaitForExit(30000) | Out-Null
            $p.ExitCode
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:Base -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes the snapshot inside the real repo, not in a garbled twin folder' {
        $repo = Join-Path $script:Base $script:Odd
        New-Item -ItemType Directory -Force $repo | Out-Null
        & git -C $repo init -q 2>$null
        $tr = Join-Path $script:Base 'transcript.jsonl'
        Set-Content -LiteralPath $tr -Value '{"a":1}'

        script:RunHook -Cwd $repo -Transcript $tr | Should -Be 0

        $snaps = @(Get-ChildItem -LiteralPath (Join-Path $repo '.agentic-board' 'compact-snapshots') -Filter *.jsonl -ErrorAction SilentlyContinue)
        $snaps.Count | Should -Be 1
        # No sibling folder that is a mis-decoding of the real one.
        @(Get-ChildItem -LiteralPath $script:Base -Directory | Where-Object Name -ne $script:Odd).Count | Should -Be 0
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
