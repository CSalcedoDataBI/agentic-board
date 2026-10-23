#Requires -Modules Pester
<#  Tests for #795: Board-Handoff.ps1 must never clobber or untrack a project-owned HANDOFF.md.

    Many repos keep a TRACKED, project-authored HANDOFF.md ("read HANDOFF.md at session start").
    -Save used to move it into .handoffs/, overwrite it with the tool's handoff and gitignore it;
    -Resume regenerated it from the issue comment the same way. Now a tracked HANDOFF.md moves the
    mirror to .handoffs/active.md and the project's file is left byte-identical and tracked.

    The end-to-end half runs the REAL script in a child pwsh against a throwaway git repo, with a
    fake `gh.cmd` first on PATH (same seam as Backup-Board.Tests.ps1): it prints the file named by
    %FAKE_GH_OUTFILE% for every call, which is all -Save (pr list, comment read, comment post) and
    -Resume (comment read) need. A .cmd is Windows-only; CI runs Pester on Windows. #>

BeforeAll {
    $script:Script = (Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Board-Handoff.ps1' | Resolve-Path).Path
    $script:Hook   = (Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Handoff-SessionStartHook.ps1' | Resolve-Path).Path
    $env:ABIOS_HANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_DOTSOURCE = ''
}

Describe 'Resolve-HandoffMirror (#795)' {
    It 'keeps the root HANDOFF.md mirror when the repo does not track one' {
        $m = Resolve-HandoffMirror
        $m.Rel    | Should -BeExactly 'HANDOFF.md'
        $m.Ignore | Should -Be @('/HANDOFF.md', '/.handoffs/')
    }
    It 'moves the mirror to .handoffs/active.md and never ignores HANDOFF.md when it is tracked' {
        $m = Resolve-HandoffMirror -RootHandoffTracked $true
        $m.Rel    | Should -BeExactly '.handoffs/active.md'
        $m.Ignore | Should -Be @('/.handoffs/')
        $m.Ignore | Should -Not -Contain '/HANDOFF.md'
    }
    It 'honours -MirrorPath over the detection, normalised to forward slashes' {
        $m = Resolve-HandoffMirror -MirrorPath '.\notes\handoff.md' -RootHandoffTracked $true
        $m.Rel    | Should -BeExactly 'notes/handoff.md'
        $m.Ignore | Should -Be @('/notes/handoff.md', '/.handoffs/')
    }
    It 'refuses a rooted -MirrorPath or one that climbs out of the repo' {
        { Resolve-HandoffMirror -MirrorPath ([System.IO.Path]::GetFullPath('x.md')) } | Should -Throw '*relative*'
        { Resolve-HandoffMirror -MirrorPath '../outside.md' } | Should -Throw "*'..'*"
    }
}

# NOT named $isWindows: that collides with PowerShell 7's read-only automatic $IsWindows.
$onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

Describe 'Board-Handoff.ps1 end to end with a tracked HANDOFF.md (#795)' -Skip:(-not $onWindows) {
    BeforeAll {
        $script:FakeDir = Join-Path $TestDrive 'fakegh'
        New-Item -ItemType Directory -Path $script:FakeDir | Out-Null
        @'
@echo off
if defined FAKE_GH_OUTFILE (type "%FAKE_GH_OUTFILE%") else (echo [])
exit /b 0
'@ | Set-Content (Join-Path $script:FakeDir 'gh.cmd') -Encoding ASCII
        $script:EmptyJson = Join-Path $TestDrive 'empty.json'
        Set-Content -Path $script:EmptyJson -Value '[]' -Encoding ASCII

        # Run the real script in a child pwsh, fake gh first on PATH, inside $Repo.
        function Invoke-Handoff([string]$Repo, [string[]]$ScriptArgs, [string]$OutFile) {
            $cmd = "`$env:PATH='$($script:FakeDir);' + `$env:PATH; `$env:GH_TOKEN='fake'; `$env:FAKE_GH_OUTFILE='$OutFile'; " +
                   "Set-Location -LiteralPath '$Repo'; & '$($script:Script)' $($ScriptArgs -join ' ')"
            $out = & pwsh -NoProfile -Command $cmd 2>&1 | Out-String
            [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
        }

        function New-TrackedRepo([string]$Name) {
            $r = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $r | Out-Null
            git -C $r init --quiet 2>&1 | Out-Null
            git -C $r config user.email 't@example.com'
            git -C $r config user.name 't'
            git -C $r config commit.gpgsign false
            git -C $r remote add origin 'https://github.com/o/r.git'
            # CRLF and no trailing newline on purpose: any rewrite would show up byte-wise.
            [System.IO.File]::WriteAllText((Join-Path $r 'HANDOFF.md'), "# Project guide`r`nRead me at session start.")
            [System.IO.File]::WriteAllText((Join-Path $r '.gitignore'), "bin/`n")
            git -C $r add HANDOFF.md .gitignore 2>&1 | Out-Null
            git -C $r commit --quiet -m 'docs: project handoff guide' 2>&1 | Out-Null
            git -C $r checkout --quiet -b issue-7-thing 2>&1 | Out-Null
            return $r
        }
        function Get-Bytes([string]$Path) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) }
    }

    It '-Save leaves the tracked HANDOFF.md byte-identical and tracked, and writes .handoffs/active.md' {
        $repo   = New-TrackedRepo 'save'
        $before = Get-Bytes (Join-Path $repo 'HANDOFF.md')
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] next'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out

        Get-Bytes (Join-Path $repo 'HANDOFF.md') | Should -BeExactly $before
        git -C $repo ls-files --error-unmatch -- HANDOFF.md 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        git -C $repo status --porcelain -- HANDOFF.md | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $repo '.handoffs/active.md') | Should -Match '# Handoff - #7'
        $gi = Get-Content -Raw (Join-Path $repo '.gitignore')
        $gi | Should -Not -Match '(?m)^/HANDOFF\.md\s*$'
        $gi | Should -Match '(?m)^/\.handoffs/\s*$'
    }

    It '-Resume from the issue comment regenerates .handoffs/active.md and leaves HANDOFF.md alone' {
        $repo   = New-TrackedRepo 'resume'
        $before = Get-Bytes (Join-Path $repo 'HANDOFF.md')
        $md = "---`nissue: 7`nrepo: o/r`nbranch: issue-7-thing`npr: null`nsaved: 2026-10-23T00:00:00Z`n---`n# Handoff - #7`n## Next concrete step`n[V] from the comment"
        $body = "<!-- abios-handoff -->`n**[abios-handoff]**`n`n" + '```md' + "`n$md`n" + '```'
        $comments = Join-Path $TestDrive 'comments.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 1; body = $body }) -Depth 5 | Set-Content -Path $comments -Encoding UTF8

        $r = Invoke-Handoff $repo @('-Resume', '-Issue', '7') $comments
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out  | Should -Match 'from the comment'

        Get-Bytes (Join-Path $repo 'HANDOFF.md') | Should -BeExactly $before
        git -C $repo status --porcelain -- HANDOFF.md | Should -BeNullOrEmpty
        Get-Content -Raw (Join-Path $repo '.handoffs/active.md') | Should -Match 'from the comment'
        Get-Content -Raw (Join-Path $repo '.gitignore') | Should -Not -Match '(?m)^/HANDOFF\.md\s*$'
    }

    It 'refuses a -MirrorPath that points at a tracked file, and writes nothing' {
        $repo   = New-TrackedRepo 'refuse'
        $before = Get-Bytes (Join-Path $repo 'HANDOFF.md')
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-MirrorPath', 'HANDOFF.md') $script:EmptyJson
        $r.Code | Should -Not -Be 0
        $r.Out  | Should -Match 'tracked by git'
        Get-Bytes (Join-Path $repo 'HANDOFF.md') | Should -BeExactly $before
        Test-Path (Join-Path $repo '.handoffs') | Should -BeFalse
    }

    It '-Save -DryRun puts the composed markdown on the success stream' {
        $repo = New-TrackedRepo 'dryrun'
        $cmd = "`$env:PATH='$($script:FakeDir);' + `$env:PATH; `$env:GH_TOKEN='fake'; `$env:FAKE_GH_OUTFILE='$($script:EmptyJson)'; " +
               "Set-Location -LiteralPath '$repo'; `$md = & '$($script:Script)' -Save -DryRun -Issue 7 -ProjectNum 1 -NoKnowledge -NextStep '[V] captured' 6>`$null; " +
               "if (`"`$md`" -match 'captured' -and `"`$md`" -match '# Handoff - #7') { 'CAPTURED' } else { 'MISSING' }"
        (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String) | Should -Match 'CAPTURED'
    }

    It 'the SessionStart hook does not mistake a tracked HANDOFF.md for a saved handoff' {
        $repo = New-TrackedRepo 'hook'
        $stdin = (@{ source = 'resume'; cwd = $repo } | ConvertTo-Json -Compress)
        ($stdin | & pwsh -NoProfile -File $script:Hook | Out-String).Trim() | Should -BeNullOrEmpty

        New-Item -ItemType Directory -Path (Join-Path $repo '.handoffs') | Out-Null
        Set-Content -Path (Join-Path $repo '.handoffs/active.md') -Value "---`nissue: 7`n---`n## Next concrete step`n[V] hooked" -Encoding UTF8
        ($stdin | & pwsh -NoProfile -File $script:Hook | Out-String) | Should -Match 'hooked'
    }
}
