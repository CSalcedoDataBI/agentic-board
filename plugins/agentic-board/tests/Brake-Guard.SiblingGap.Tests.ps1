#Requires -Modules Pester
<#  The sibling git-push patterns must not lose a push to a quoted `&` or a mid-command redirection (#707).

    #703 fixed the `--delete` pattern. Its three siblings - the `:refspec` delete and the two merges to
    main - kept a gap of `[^;&|<>]*`, which ends at `&`, `<` and `>`. Quotes are stripped before the
    patterns run, so
        git push origin -o "nota & extra" HEAD:main
    read as a background operator followed by a different command, and
        git push origin >/dev/null HEAD:main
    hid the refspec behind a redirection. Both are real pushes to main that the brake let through.

    This is a SAFETY-SENSITIVE file, so the fix is held to one rule: it may only ADD refusals (or
    remove a false positive proven plain). Every group below is in one of those directions:
    "the command is now denied", "the plain background `&` is still not a boundary violation", or
    "over generated commands nothing the old patterns denied is allowed now". #>

BeforeAll {
    $script:GuardPath = Join-Path $PSScriptRoot '..' 'scripts' 'Brake-Guard.ps1' | Resolve-Path
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . $script:GuardPath
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = ''
    $script:AllIrr = @('merge', 'deploy', 'refresh', 'publish', 'delete')
    function script:Classify([string]$c) { Test-IsBrakedCommand -Command $c -Irreversible $script:AllIrr }
    $script:Bs = [string][char]92
}

Describe 'a quoted or escaped & does not hide a push to main (#707)' {
    It '<cmd> is a merge' -ForEach @(
        @{ cmd = 'git push origin -o "nota & extra" HEAD:main' }                 # the reported case
        @{ cmd = 'git push origin -o "nota & extra" main' }
        @{ cmd = 'git push origin "a&b" main' }
        @{ cmd = 'git push origin "a&b:main"' }                                    # the refspec itself carries the &
        @{ cmd = 'git push origin "x" & echo main' }                               # quotes make the & ambiguous: fail closed
        @{ cmd = 'git push origin a\&b HEAD:main' }
        @{ cmd = 'git push origin $(echo a&b) HEAD:main' }
        @{ cmd = 'git push origin `echo a&b` HEAD:main' }
        @{ cmd = 'cmd /c git push origin a^&b HEAD:main' }
        @{ cmd = 'git push origin @(a&b) HEAD:main' }                              # extglob
        @{ cmd = 'git push origin {a,b}& HEAD:main' }
        @{ cmd = 'git push origin "a" + "b" & HEAD:refs/heads/main' }
    ) {
        Classify $cmd | Should -Be 'merge'
    }
    It '<cmd> is a delete' -ForEach @(
        @{ cmd = 'git push origin -o "nota & extra" :feature' }                   # the reported case
        @{ cmd = 'git push origin a\&b :feature' }
        @{ cmd = 'git push origin $(echo a&b) :feature' }
        @{ cmd = 'git push origin `echo a&b` :feature' }
        @{ cmd = 'git push origin {a,b}& :feature' }
        @{ cmd = 'git push origin "x" & echo :y' }
    ) {
        Classify $cmd | Should -Be 'delete'
    }
}

Describe 'a redirection in the middle of the command does not hide the push (#707)' {
    It '<cmd> is a merge' -ForEach @(
        @{ cmd = 'git push origin >/dev/null HEAD:main' }                          # the reported case
        @{ cmd = 'git push origin 2>&1 HEAD:main' }
        @{ cmd = 'git push origin >/dev/null main' }
        @{ cmd = 'git push origin &>out.txt HEAD:main' }
        @{ cmd = 'git push origin <in.txt HEAD:main' }
        @{ cmd = 'git push origin >>out.txt 2>&1 +HEAD:refs/heads/master' }
        @{ cmd = 'git push >/dev/null origin HEAD:main' }
    ) {
        Classify $cmd | Should -Be 'merge'
    }
    It '<cmd> is a delete' -ForEach @(
        @{ cmd = 'git push origin 2>&1 :feature' }                                 # the reported case
        @{ cmd = 'git push origin >/dev/null :feature' }
        @{ cmd = 'git push origin &>out.txt :feature' }
        @{ cmd = 'git push origin <in.txt :feature' }
    ) {
        Classify $cmd | Should -Be 'delete'
    }
}

Describe 'a plain background & is still a boundary, so the over-block stays fixed' {
    # These are two commands. The text after the & belongs to the second one, and nothing in a
    # PLAIN command can make that & an argument character.
    It '<cmd>' -ForEach @(
        @{ cmd = 'git push origin fine & echo main' }
        @{ cmd = 'git push origin fine & echo :y' }
        @{ cmd = 'git push origin fine & echo HEAD:main' }
        @{ cmd = 'git push origin fine& echo main' }
        @{ cmd = 'git push origin fine >log.txt & echo main' }                     # redirect THEN separator
        @{ cmd = 'git push origin fine 2>&1 & echo :y' }
        @{ cmd = 'git push origin fine 2>&1 & echo HEAD:main' }
    ) {
        Classify $cmd | Should -BeNullOrEmpty
    }
    It 'a real second push after the & is still judged on its own' {
        Classify 'git push origin fine & git push origin HEAD:main' | Should -Be 'merge'
        Classify 'git push origin fine & git push origin :old' | Should -Be 'delete'
    }
}

Describe 'the real push patterns and ordinary pushes are unchanged' {
    It '<cmd> is denied as <want>' -ForEach @(
        @{ cmd = 'git push origin HEAD:main'; want = 'merge' }
        @{ cmd = 'git push origin main'; want = 'merge' }
        @{ cmd = 'git push origin +HEAD:refs/heads/master'; want = 'merge' }
        @{ cmd = 'git push origin :feature'; want = 'delete' }
        @{ cmd = 'git -C . push origin HEAD:main'; want = 'merge' }
        @{ cmd = 'git -c a=1 -c b=2 push origin :feature'; want = 'delete' }
    ) {
        Classify $cmd | Should -Be $want
    }
    It '<cmd> is allowed' -ForEach @(
        @{ cmd = 'git push origin feature' }
        @{ cmd = 'git push -u origin my-feature 2>&1' }
        @{ cmd = 'git push origin main-cleanup' }                                  # `main` only as a prefix
        @{ cmd = 'git push origin master.bak' }
        @{ cmd = 'git push origin maintenance' }
        @{ cmd = 'git push origin "feat" 2>&1' }                                   # not plain, has &<>, no target
        @{ cmd = 'git push origin $branch 2>&1' }
        @{ cmd = 'git push origin feat 2>&1 | tail -3' }
        @{ cmd = 'git commit -m "push to main" & echo hi' }                        # `git commit`, not a push
        @{ cmd = 'git log --oneline > out.txt' }
        @{ cmd = 'git status & git push origin feat' }
    ) {
        Classify $cmd | Should -BeNullOrEmpty
    }
}

Describe 'git global options that carry a quoted & do not shake the pattern off (#707)' {
    # `$script:GitCmd` stops a global-option token at `&`: right for a plain command, wrong for
    # `-c "a&b=1"` where the & is inside a value. The fallback uses a prefix that does not.
    It '<cmd> is <want>' -ForEach @(
        @{ cmd = 'git -c "a&b=1" push origin HEAD:main'; want = 'merge' }
        @{ cmd = 'git -c "a&b=1" push origin :feature'; want = 'delete' }
        @{ cmd = 'git -c "a&b=1" push origin --delete feature'; want = 'delete' }
        @{ cmd = 'git -c "a&b=1" -C . push origin main'; want = 'merge' }
    ) {
        Classify $cmd | Should -Be $want
    }
    It 'a commit whose message mentions a push is still not a push' {
        Classify 'git -c "a&b=1" commit -m "push to main"' | Should -BeNullOrEmpty
    }
}

Describe 'the fallback follows the contract' {
    It 'a contract without merge does not brake a quoted-& push to main' {
        Test-IsBrakedCommand -Command 'git push origin -o "a & b" HEAD:main' -Irreversible @('delete') | Should -BeNullOrEmpty
    }
    It 'a contract without delete does not brake a quoted-& delete' {
        Test-IsBrakedCommand -Command 'git push origin -o "a & b" :feature' -Irreversible @('merge') | Should -BeNullOrEmpty
    }
    It 'each verdict is reported under its own action' {
        Test-IsBrakedCommand -Command 'git push origin -o "a & b" HEAD:main' -Irreversible @('merge') | Should -Be 'merge'
        Test-IsBrakedCommand -Command 'git push origin -o "a & b" :feature' -Irreversible @('delete') | Should -Be 'delete'
    }
}

Describe 'the classifier never becomes looser, over generated commands' {
    It 'nothing the OLD sibling patterns denied is allowed now, and every new refusal has a reason' {
        # OLD = the classifier with the three sibling patterns swapped back to their pre-#707 text and
        # the fallback reduced to what #703 shipped (one --delete pattern, no wider git prefix).
        $oldSiblings = @{
            merge1 = $script:GitCmd + 'push\b[^;&|<>]*\s\+?[^\s;|&]+:(?:refs/heads/)?(main|master)(?=[\s;&|<>]|$)'
            merge2 = $script:GitCmd + 'push\b[^;&|<>]*\s(main|master)(?=[\s;&|<>]|$)'
            del    = $script:GitCmd + 'push\b[^;&|<>]*\s:\S'
        }
        $newPlain = @{}
        $siblings = @($script:BrakePatterns | Where-Object { $_.pattern.Contains($script:PushGap) -and -not $_.pattern.Contains('--delete') })
        $siblings.Count | Should -Be 3
        $newAmbig = @($script:AmbiguousPushPatterns)
        $newAmbig.Count | Should -Be 4
        $saved = @($siblings | ForEach-Object { $_.pattern }); $savedAmbig = @($newAmbig | ForEach-Object { @{ a = $_.action; p = $_.pattern } })
        $useOld = {
            $siblings[0].pattern = $oldSiblings.merge1; $siblings[1].pattern = $oldSiblings.merge2; $siblings[2].pattern = $oldSiblings.del
            $newAmbig[0].pattern = $script:GitCmd + 'push\b.*--delete\b'
            1..3 | ForEach-Object { $newAmbig[$_].action = 'none' }
        }
        $useNew = {
            0..2 | ForEach-Object { $siblings[$_].pattern = $saved[$_] }
            0..3 | ForEach-Object { $newAmbig[$_].action = $savedAmbig[$_].a; $newAmbig[$_].pattern = $savedAmbig[$_].p }
        }
        $tokens = @('git push origin', 'x', 'HEAD:main', 'main', ':y', '--delete', '&', '2>&1', '>out.txt', '&>o.txt', '<in.txt', '>/dev/null',
                    'echo', '&&', ';', '|', '-f', '"a&b"', "'x & y'", '"q"', '\&', '$(echo a&b)', 'a`&b', '{a,b}', '-c "k&v"')
        $isRedirect = '^(\d*>>?&?\S*|&>>?\S*|<\S*)$'
        $rng = New-Object System.Random 707
        $checked = 0; $added = 0; $addedPlain = 0
        try {
            for ($i = 0; $i -lt 4000; $i++) {
                $n = $rng.Next(2, 9)
                $words = 1..$n | ForEach-Object { $tokens[$rng.Next($tokens.Count)] }
                $cmd = 'git push ' + ($words -join ' ')
                & $useNew; $new = Test-IsBrakedCommand -Command $cmd -Irreversible @('merge', 'delete')
                & $useOld; $old = Test-IsBrakedCommand -Command $cmd -Irreversible @('merge', 'delete')
                $checked++
                if ($old -and -not $new) { throw "LOOSER: old denies, new allows: '$cmd'" }
                if ($new -and -not $old) {
                    $added++
                    $plain = $cmd -match $script:PlainCommandPattern
                    if ($plain) {
                        # Independent oracle for a PLAIN command: drop the redirection words; the old
                        # classifier on what is left must already have denied it.
                        $stripped = 'git push ' + (($words | Where-Object { $_ -notmatch $isRedirect }) -join ' ')
                        $oldStripped = Test-IsBrakedCommand -Command $stripped -Irreversible @('merge', 'delete')
                        if (-not $oldStripped) { throw "NEW refuses a plain command whose redirect-free form the old one allowed: '$cmd'" }
                        $addedPlain++
                    } elseif ($cmd -notmatch '[&<>]') {
                        throw "NEW refuses a non-plain command with no & < > in it (narrow and unbounded agree there): '$cmd'"
                    }
                }
            }
        } finally { & $useNew }
        $checked | Should -BeGreaterThan 3000
        $added | Should -BeGreaterThan 100        # the generator does reach the fixed cases
        $addedPlain | Should -BeGreaterThan 0     # ...including the plain, redirection-only ones
    }
    It 'a non-plain command with an ampersand or a redirection is judged by an independent unbounded oracle' {
        # Oracle: any git push whose text, anywhere after `push`, carries a delete flag, a `:x`, or a
        # main/master target is refused. Written without the gap patterns under test.
        $oracle = '\bgit\b.*\bpush\b.*(--delete\b|\s:\S|\s\+?\S+:(main|master)(?=[\s;&|<>]|$)|\s(main|master)(?=[\s;&|<>]|$))'
        $tokens = @('git push origin', 'x', 'HEAD:main', 'main', ':y', '--delete', '&', '>o.txt', '2>&1', '"a&b"', "'x & y'", '\&', '$(echo a&b)', 'echo', '{a,b}')
        $rng = New-Object System.Random 7077
        $refused = 0
        for ($i = 0; $i -lt 3000; $i++) {
            $n = $rng.Next(2, 8)
            $cmd = 'git push ' + ((1..$n | ForEach-Object { $tokens[$rng.Next($tokens.Count)] }) -join ' ')
            if ($cmd -match $script:PlainCommandPattern -or $cmd -notmatch '[&<>]') { continue }
            $hit = $false
            foreach ($seg in ((ConvertTo-NormalizedCommand $cmd) -split $script:SegmentSeparator)) {
                if ($seg -match $oracle) { $hit = $true }
            }
            if ($hit) {
                $refused++
                if (-not (Classify $cmd)) { throw "HOLE: the oracle refuses but the brake allows: '$cmd'" }
            }
        }
        $refused | Should -BeGreaterThan 200
    }
}

Describe 'the classifier stays linear on a hostile command' {
    It '<name>' -ForEach @(
        @{ name = '3000 redirections then a push to main (plain): denied'; cmd = 'git push origin ' + ('2>&1 ' * 3000) + 'HEAD:main'; want = 'merge' }
        @{ name = '3000 redirections and no target (plain): allowed'; cmd = 'git push origin ' + ('>&> ' * 3000) + 'x'; want = '' }
        @{ name = '3000 quoted-& words then a push to main (not plain): denied'; cmd = 'git push origin ' + ('"a&b" ' * 3000) + 'HEAD:main'; want = 'merge' }
        @{ name = '3000 quoted-& words and no target (not plain): allowed'; cmd = 'git push origin ' + ('"a&b" ' * 3000) + 'x'; want = '' }
        @{ name = '2000 -c options with a quoted & then a push to main: denied'; cmd = 'git ' + ('-c "k&v=1" ' * 2000) + 'push origin HEAD:main'; want = 'merge' }
        @{ name = '2000 -c options with a quoted & and no push: allowed'; cmd = 'git ' + ('-c "k&v=1" ' * 2000) + 'status'; want = '' }
        @{ name = '1500 `git push` words, not plain, no target: allowed'; cmd = ('git push a "&" ' * 1500) + 'x'; want = '' }
    ) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Classify $cmd
        $sw.Stop()
        "$r" | Should -Be $want
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
    }
}
