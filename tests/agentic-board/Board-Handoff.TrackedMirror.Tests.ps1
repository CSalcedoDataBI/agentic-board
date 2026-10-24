#Requires -Modules Pester
<#  Tests for #795: Board-Handoff.ps1 must never clobber or untrack a project-owned HANDOFF.md.

    Many repos keep a TRACKED, project-authored HANDOFF.md ("read HANDOFF.md at session start").
    -Save used to move it into .handoffs/, overwrite it with the tool's handoff and gitignore it;
    -Resume regenerated it from the issue comment the same way. Now a tracked HANDOFF.md moves the
    mirror to .handoffs/active.md and the project's file is left byte-identical and tracked.

    The end-to-end half runs the REAL script in a child pwsh against a throwaway git repo, with a
    fake `gh.cmd` first on PATH (same seam as Backup-Board.Tests.ps1): it prints the file named by
    %FAKE_GH_OUTFILE% for every call, which is all -Save (pr list, comment read, comment post) and
    -Resume (comment read) need. A .cmd is Windows-only, so that half runs on the Windows CI leg
    and is skipped on Linux; the gh-free hook test runs on both. #>

BeforeAll {
    $script:Script = (Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Board-Handoff.ps1' | Resolve-Path).Path
    $script:Hook   = (Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Handoff-SessionStartHook.ps1' | Resolve-Path).Path
    $env:ABIOS_HANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_DOTSOURCE = ''

    # A throwaway repo that tracks a project-authored HANDOFF.md, on an issue-<n> branch.
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
    # The SessionStart hook as Claude Code runs it: JSON on stdin, context JSON (or nothing) on stdout.
    function Invoke-Hook([string]$Repo) {
        $stdin = (@{ source = 'resume'; cwd = $Repo } | ConvertTo-Json -Compress)
        return ($stdin | & pwsh -NoProfile -File $script:Hook 2>&1 | Out-String).Trim()
    }
}

# Needs no gh, so it runs on every platform (the Linux CI leg included).
Describe 'Handoff-SessionStartHook end to end with a tracked HANDOFF.md (#795)' {
    It 'does not mistake a tracked HANDOFF.md for a saved handoff, and reads .handoffs/active.md instead' {
        $repo = New-TrackedRepo 'hook'
        # A guide that LOOKS like a handoff to the old hook (it has the heading the hook quotes), and
        # even mentions the keys in its body - but carries no handoff frontmatter.
        [System.IO.File]::WriteAllText((Join-Path $repo 'HANDOFF.md'), "# Guide`nsaved: always`nverified: by hand`n## Next concrete step`nread the guide")
        git -C $repo commit --quiet -am 'docs: guide' 2>&1 | Out-Null
        Invoke-Hook $repo | Should -BeNullOrEmpty

        New-Item -ItemType Directory -Path (Join-Path $repo '.handoffs') | Out-Null
        Set-Content -Path (Join-Path $repo '.handoffs/active.md') -Value "---`nissue: 7`n---`n## Next concrete step`n[V] hooked" -Encoding UTF8
        $h = Invoke-Hook $repo
        $h | Should -Match 'hooked'
        $h | Should -Not -Match 'read the guide'
    }
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
    It 'canonicalises inner "." and empty segments (git prints tracked paths canonically)' {
        (Resolve-HandoffMirror -MirrorPath 'docs/./guide.md').Rel  | Should -BeExactly 'docs/guide.md'
        (Resolve-HandoffMirror -MirrorPath 'docs//guide.md').Rel   | Should -BeExactly 'docs/guide.md'
        (Resolve-HandoffMirror -MirrorPath 'docs\.\guide.md').Rel  | Should -BeExactly 'docs/guide.md'
    }
    It 'refuses a rooted -MirrorPath or one that climbs out of the repo' {
        { Resolve-HandoffMirror -MirrorPath ([System.IO.Path]::GetFullPath('x.md')) } | Should -Throw '*relative*'
        { Resolve-HandoffMirror -MirrorPath '../outside.md' } | Should -Throw "*'..'*"
    }
    It 'refuses Win32 aliases (trailing dot or space, a stream colon) that open a different file' {
        foreach ($w in 'HANDOFF.md.', 'HANDOFF.md ', 'docs./x.md', 'x.md:stream') {
            { Resolve-HandoffMirror -MirrorPath $w } | Should -Throw "*Windows would open*" -Because "[$w]"
        }
    }
    It 'refuses wildcard characters (a -Path cmdlet would hit other files than the guard judged)' {
        foreach ($w in 'docs/*.md', 'h?.md', 'handoff[1].md') {
            { Resolve-HandoffMirror -MirrorPath $w } | Should -Throw '*wildcard*' -Because $w
        }
    }
}

# One table, two detectors: Board-Handoff.ps1's Test-HandoffMirrorText and the hook's
# Test-HandoffFrontmatter must both give the EXPECTED answer, not merely agree with each other.
Describe 'Handoff frontmatter detection, script and hook (#795 review)' {
    BeforeAll {
        $env:ABIOS_HANDOFF_HOOK_DOTSOURCE = '1'
        . $script:Hook
        $env:ABIOS_HANDOFF_HOOK_DOTSOURCE = ''
        $fm = "---`nissue: 7`nsaved: 2026-10-23T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7"
        $script:Cases = @(
            @{ Name = 'a handoff this script wrote';                  Text = $fm;                                  Expected = $true }
            @{ Name = 'the same with CRLF line ends';                 Text = $fm -replace "`n", "`r`n";            Expected = $true }
            @{ Name = 'the same behind a UTF-8 BOM';                 Text = "$([char]0xFEFF)$fm";                 Expected = $true }
            @{ Name = 'a plain project guide';                       Text = "# Project guide`nRead me.";          Expected = $false }
            @{ Name = 'empty text';                                  Text = '';                                   Expected = $false }
            @{ Name = 'frontmatter with saved only';                 Text = "---`nsaved: x`n---`n# x";             Expected = $false }
            @{ Name = 'frontmatter with verified only';              Text = "---`nverified: 1/1`n---`n# x";        Expected = $false }
            @{ Name = 'an empty saved value';                        Text = "---`nsaved:`nverified: 1/1`n---";     Expected = $false }
            @{ Name = 'the keys in the body, no frontmatter';        Text = "# Guide`nsaved: x`nverified: y";      Expected = $false }
            @{ Name = 'ordinary frontmatter, then the keys in body'; Text = "---`ntitle: Guide`n---`nsaved: x`nverified: y"; Expected = $false }
            @{ Name = 'frontmatter without the keys';                Text = "---`ntitle: x`n---";                  Expected = $false }
            @{ Name = 'an unterminated block';                       Text = "---`nsaved: x`nverified: y";          Expected = $false }
        )
    }
    It 'Test-HandoffMirrorText (script) gives the expected answer for every case' {
        foreach ($c in $script:Cases) { Test-HandoffMirrorText $c.Text | Should -Be $c.Expected -Because $c.Name }
    }
    It 'Test-HandoffFrontmatter (hook) gives the expected answer for every case' {
        foreach ($c in $script:Cases) { Test-HandoffFrontmatter $c.Text | Should -Be $c.Expected -Because $c.Name }
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
        # An issue whose [abios-handoff] comment holds a valid handoff (for -Resume write paths).
        $vmd = "---`nissue: 7`nrepo: o/r`nbranch: issue-7-thing`npr: null`nsaved: 2026-10-23T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7`n## Next concrete step`n[V] valid comment"
        $vbody = "<!-- abios-handoff -->`n**[abios-handoff]**`n`n" + '```md' + "`n$vmd`n" + '```'
        $script:ValidComments = Join-Path $TestDrive 'comments-valid.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 1; body = $vbody }) -Depth 5 | Set-Content -Path $script:ValidComments -Encoding UTF8

        # Run the real script in a child pwsh, fake gh first on PATH, inside $Repo.
        function Invoke-Handoff([string]$Repo, [string[]]$ScriptArgs, [string]$OutFile) {
            $cmd = "`$env:PATH='$($script:FakeDir);' + `$env:PATH; `$env:GH_TOKEN='fake'; `$env:FAKE_GH_OUTFILE='$OutFile'; " +
                   "Set-Location -LiteralPath '$Repo'; & '$($script:Script)' $($ScriptArgs -join ' ')"
            $out = & pwsh -NoProfile -Command $cmd 2>&1 | Out-String
            [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
        }
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

    It 'refuses a -MirrorPath that points at a tracked file (any spelling), and writes nothing' {
        $repo   = New-TrackedRepo 'refuse'
        $before = Get-Bytes (Join-Path $repo 'HANDOFF.md')
        # A tracked directory and a tracked non-ASCII name (ls-files would octal-quote it by default).
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'docs/a.md'), 'a')
        [System.IO.File]::WriteAllText((Join-Path $repo "notas-$([char]0xE9).md"), 'n')
        git -C $repo add -A 2>&1 | Out-Null
        git -C $repo commit --quiet -m 'docs: more tracked files' 2>&1 | Out-Null
        $giBefore   = Get-Bytes (Join-Path $repo '.gitignore')
        $docsBefore = Get-Bytes (Join-Path $repo 'docs/a.md')
        $notaBefore = Get-Bytes (Join-Path $repo "notas-$([char]0xE9).md")
        foreach ($spelling in '.gitignore', './/.gitignore', '.GITIGNORE', 'HANDOFF.md', 'handoff.md', 'docs', 'docs/', "notas-$([char]0xE9).md") {
            # -Resume runs WITH a valid comment, so the regenerate-from-comment write path is the one refused.
            foreach ($verb in '-Save', '-Resume') {
                $src = if ($verb -eq '-Resume') { $script:ValidComments } else { $script:EmptyJson }
                $r = Invoke-Handoff $repo @($verb, '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] next'", '-MirrorPath', "'$spelling'") $src
                $r.Code | Should -Not -Be 0 -Because "$verb $spelling"
                $r.Out  | Should -Match 'is tracked by git \(or holds tracked files\) and is not a handoff' -Because "$verb $spelling -> $($r.Out)"
            }
        }
        Get-Bytes (Join-Path $repo '.gitignore') | Should -BeExactly $giBefore
        Get-Bytes (Join-Path $repo 'HANDOFF.md') | Should -BeExactly $before
        Get-Bytes (Join-Path $repo 'docs/a.md') | Should -BeExactly $docsBefore
        Get-Bytes (Join-Path $repo "notas-$([char]0xE9).md") | Should -BeExactly $notaBefore
        Test-Path (Join-Path $repo '.handoffs') | Should -BeFalse
        git -C $repo config --local --get abios.handoffMirror | Should -BeNullOrEmpty
        git -C $repo status --porcelain | Should -BeNullOrEmpty
    }

    It 'refuses an untracked directory or the (populated) archive dir as -MirrorPath, writing nothing' {
        $repo = New-TrackedRepo 'dirmirror'
        # A prior real -Save, so .handoffs/ holds active.md (and the next one an archive).
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] first'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        New-Item -ItemType Directory -Path (Join-Path $repo 'scratch') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'scratch/keep.txt'), 'k')
        $giBefore     = Get-Bytes (Join-Path $repo '.gitignore')
        $activeBefore = Get-Bytes (Join-Path $repo '.handoffs/active.md')
        foreach ($spelling in 'scratch', '.handoffs', '.HANDOFFS') {
            $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] next'", '-MirrorPath', $spelling) $script:EmptyJson
            $r.Code | Should -Not -Be 0 -Because $spelling
            $r.Out  | Should -Match 'is a directory' -Because $r.Out
        }
        Get-Bytes (Join-Path $repo '.gitignore') | Should -BeExactly $giBefore
        Get-Bytes (Join-Path $repo '.handoffs/active.md') | Should -BeExactly $activeBefore
        @(Get-ChildItem (Join-Path $repo '.handoffs')).Count | Should -Be 1
        Get-Content -Raw (Join-Path $repo 'scratch/keep.txt') | Should -BeExactly 'k'
        git -C $repo config --local --get abios.handoffMirror | Should -BeNullOrEmpty
    }

    It '-Resume -MirrorPath remembers the location on a machine with no local config' {
        $repo = New-TrackedRepo 'resume-custom'
        $md = "---`nissue: 7`nrepo: o/r`nbranch: issue-7-thing`npr: null`nsaved: 2026-10-23T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7`n## Next concrete step`n[V] from machine A"
        $body = "<!-- abios-handoff -->`n**[abios-handoff]**`n`n" + '```md' + "`n$md`n" + '```'
        $comments = Join-Path $TestDrive 'comments-custom.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 1; body = $body }) -Depth 5 | Set-Content -Path $comments -Encoding UTF8
        $r = Invoke-Handoff $repo @('-Resume', '-Issue', '7', '-MirrorPath', 'notes/r.md') $comments
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Content -Raw (Join-Path $repo 'notes/r.md') | Should -Match 'from machine A'
        (git -C $repo config --local --get abios.handoffMirror) | Should -BeExactly 'notes/r.md'
        Invoke-Hook $repo | Should -Match 'from machine A'
    }

    It 'a second -Save rotates .handoffs/active.md into one archive and keeps the guide untouched' {
        $repo   = New-TrackedRepo 'twice'
        $before = Get-Bytes (Join-Path $repo 'HANDOFF.md')
        foreach ($n in 'first', 'second') {
            $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] $n'") $script:EmptyJson
            $r.Code | Should -Be 0 -Because $r.Out
        }
        Get-Content -Raw (Join-Path $repo '.handoffs/active.md') | Should -Match 'second'
        $archives = @(Get-ChildItem (Join-Path $repo '.handoffs') -Filter '*-handoff.md')
        $archives.Count | Should -Be 1
        Get-Content -Raw $archives[0].FullName | Should -Match 'first'
        Get-Bytes (Join-Path $repo 'HANDOFF.md') | Should -BeExactly $before
    }

    It 'a force-committed mirror (the tool''s own -Save output, git add -f) is still used as the mirror' {
        $repo = New-TrackedRepo 'forced'
        # Untrack the project guide so the first -Save writes the classic root mirror, exactly as the tool does.
        git -C $repo rm --quiet HANDOFF.md 2>&1 | Out-Null
        git -C $repo commit --quiet -m 'chore: drop guide' 2>&1 | Out-Null
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] old'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        git -C $repo add -f HANDOFF.md 2>&1 | Out-Null
        git -C $repo commit --quiet -m 'chore: force-commit the handoff' 2>&1 | Out-Null

        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] fresh'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Content -Raw (Join-Path $repo 'HANDOFF.md') | Should -Match 'fresh'
        Test-Path (Join-Path $repo '.handoffs/active.md') | Should -BeFalse
        Invoke-Hook $repo | Should -Match 'fresh'
    }

    It 'remembers -MirrorPath (non-ASCII too), so a later -Resume and the hook find it without the flag' {
        $repo = New-TrackedRepo 'custom'
        $name = "notes/$([char]0xFC)bergabe.md"
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-MirrorPath', "'$name'", '-NextStep', "'[V] custom spot'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        Test-Path -LiteralPath (Join-Path $repo $name) | Should -BeTrue
        $prev = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); (git -C $repo config --local --get abios.handoffMirror) | Should -BeExactly $name }
        finally { [Console]::OutputEncoding = $prev }

        # No [abios-handoff] comment on the issue: -Resume must fall back to the remembered mirror.
        $res = Invoke-Handoff $repo @('-Resume', '-Issue', '7', '-DryRun') $script:EmptyJson
        $res.Code | Should -Be 0 -Because $res.Out
        $res.Out  | Should -Match 'custom spot'
        Invoke-Hook $repo | Should -Match 'custom spot'
    }

    It 'judges the COMMITTED copy, and adopts a handoff the old version wrote over the guide before advising a restore' {
        $repo = New-TrackedRepo 'clobbered'
        $stale = "---`nissue: 7`nsaved: 2026-10-01T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7`n## Next concrete step`n[V] old"
        [System.IO.File]::WriteAllText((Join-Path $repo 'HANDOFF.md'), $stale)

        # Offline -Resume (no comment) finds the clobbered handoff through the adopted mirror.
        $res = Invoke-Handoff $repo @('-Resume', '-Issue', '7') $script:EmptyJson
        $res.Code | Should -Be 0 -Because $res.Out
        $res.Out  | Should -Match '\[V\] old'
        $res.Out  | Should -Match 'kept in \.handoffs/active\.md'
        $res.Out  | Should -Match 'git checkout -- HANDOFF\.md'

        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] fresh'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Content -Raw (Join-Path $repo '.handoffs/active.md') | Should -Match 'fresh'
        $archives = @(Get-ChildItem (Join-Path $repo '.handoffs') -Filter '*-handoff.md')
        $archives.Count | Should -Be 1
        Get-Content -Raw $archives[0].FullName | Should -Match '\[V\] old'
        [System.IO.File]::ReadAllText((Join-Path $repo 'HANDOFF.md')) | Should -BeExactly $stale
        Get-Content -Raw (Join-Path $repo '.gitignore') | Should -Not -Match '(?m)^/HANDOFF\.md\s*$'
        # The hook judges the same committed copy: it surfaces the new mirror, not the stale file on disk.
        $h = Invoke-Hook $repo
        $h | Should -Match 'fresh'
        $h | Should -Not -Match 'Next step: old'
    }

    It '-Resume from a comment archives an adopted clobbered handoff instead of overwriting it' {
        $repo  = New-TrackedRepo 'clobbered-resume'
        $stale = "---`nissue: 7`nsaved: 2026-10-01T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7`n## Next concrete step`n[V] local only"
        [System.IO.File]::WriteAllText((Join-Path $repo 'HANDOFF.md'), $stale)
        $md = "---`nissue: 7`nrepo: o/r`nbranch: issue-7-thing`npr: null`nsaved: 2026-10-23T00:00:00Z`nverified: 1/1`n---`n# Handoff - #7`n## Next concrete step`n[V] from the comment"
        $body = "<!-- abios-handoff -->`n**[abios-handoff]**`n`n" + '```md' + "`n$md`n" + '```'
        $comments = Join-Path $TestDrive 'comments-clobbered.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 1; body = $body }) -Depth 5 | Set-Content -Path $comments -Encoding UTF8

        $r = Invoke-Handoff $repo @('-Resume', '-Issue', '7') $comments
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Content -Raw (Join-Path $repo '.handoffs/active.md') | Should -Match 'from the comment'
        $archives = @(Get-ChildItem (Join-Path $repo '.handoffs') -Filter '*-handoff.md')
        $archives.Count | Should -Be 1
        Get-Content -Raw $archives[0].FullName | Should -Match 'local only'
        [System.IO.File]::ReadAllText((Join-Path $repo 'HANDOFF.md')) | Should -BeExactly $stale
    }

    It 'detects a tracked HANDOFF.md whatever its case (NTFS resolves both names to one file)' {
        $repo = New-TrackedRepo 'icase'
        git -C $repo mv HANDOFF.md tmp.md 2>&1 | Out-Null
        git -C $repo mv tmp.md Handoff.md 2>&1 | Out-Null
        git -C $repo commit --quiet -m 'docs: rename guide' 2>&1 | Out-Null
        $before = Get-Bytes (Join-Path $repo 'Handoff.md')
        $r = Invoke-Handoff $repo @('-Save', '-Issue', '7', '-ProjectNum', '1', '-NoMemo', '-NoKnowledge', '-NextStep', "'[V] next'") $script:EmptyJson
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Bytes (Join-Path $repo 'Handoff.md') | Should -BeExactly $before
        Test-Path (Join-Path $repo '.handoffs/active.md') | Should -BeTrue
        Invoke-Hook $repo | Should -Match 'Next step: next'
    }

    It '-Save -DryRun puts the composed markdown on the success stream' {
        $repo = New-TrackedRepo 'dryrun'
        $cmd = "`$env:PATH='$($script:FakeDir);' + `$env:PATH; `$env:GH_TOKEN='fake'; `$env:FAKE_GH_OUTFILE='$($script:EmptyJson)'; " +
               "Set-Location -LiteralPath '$repo'; `$md = & '$($script:Script)' -Save -DryRun -Issue 7 -ProjectNum 1 -NoKnowledge -NextStep '[V] captured' 6>`$null; " +
               "if (`"`$md`" -match 'captured' -and `"`$md`" -match '# Handoff - #7') { 'MD_ON_SUCCESS_STREAM' } else { 'MD_NOT_CAPTURED' }"
        $out = (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String)
        $out | Should -MatchExactly 'MD_ON_SUCCESS_STREAM'
        $out | Should -Not -Match 'MD_NOT_CAPTURED'
    }

}
