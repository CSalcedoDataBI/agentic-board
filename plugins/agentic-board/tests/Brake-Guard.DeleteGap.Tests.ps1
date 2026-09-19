#Requires -Modules Pester
<#  The `--delete` git-push pattern must not step over a background `&` (#546).

    #542 round 6 narrowed the prefix of three git-push patterns from an unbounded gap to one that
    stops at a background `&`; the `--delete` pattern kept `.*`, so
        git push origin mi-rama-normal & echo --delete
    was classified `delete` while deleting nothing. This is a SAFETY-SENSITIVE file, so the fix is
    held to one rule: it may only REMOVE a false positive. Every test below is in one of two
    directions - "a real delete is still denied" and "text after a separating & no longer is" -
    and the last group proves, over generated commands, that nothing the old pattern denied is
    allowed now except where a separating & sits between `push` and `--delete`. #>

BeforeAll {
    $script:GuardPath = Join-Path $PSScriptRoot '..' 'scripts' 'Brake-Guard.ps1' | Resolve-Path
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . $script:GuardPath
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = ''
    $script:AllIrr = @('merge', 'deploy', 'refresh', 'publish', 'delete')
    function script:Classify([string]$c) { Test-IsBrakedCommand -Command $c -Irreversible $script:AllIrr }
}

Describe 'a REAL branch delete is still denied' {
    It '<cmd>' -ForEach @(
        @{ cmd = 'git push origin --delete feature' }
        @{ cmd = 'git push --delete origin feature' }
        @{ cmd = 'git push origin feature --delete' }
        @{ cmd = 'git -C . push origin --delete feature' }
        @{ cmd = 'git -c a=1 -c b=2 push origin --delete feature' }
        @{ cmd = 'git push origin feature-a feature-b --delete' }
        @{ cmd = 'git push origin :feature' }                                # refspec spelling
        @{ cmd = 'git push origin x; git push --delete origin y' }           # a later SEGMENT
        @{ cmd = 'git push origin x && git push origin --delete y' }
        @{ cmd = 'git push origin x & git push origin --delete y' }          # a REAL second push after &
        @{ cmd = 'git push origin x & git push origin :y' }
    ) {
        Classify $cmd | Should -Be 'delete'
    }
}

Describe 'a redirection between `push` and `--delete` does NOT open a hole' {
    # A redirection is not a command separator: the words around it still belong to the same
    # command. A gap that treated `>`, `<` or the `&` inside `2>&1` / `&>` as a boundary would
    # ALLOW these, which the unbounded pattern denied - the failure the fix must not introduce.
    It '<cmd>' -ForEach @(
        @{ cmd = 'git push origin >out.txt --delete feature' }
        @{ cmd = 'git push origin 2>&1 --delete feature' }
        @{ cmd = 'git push origin &>out.txt --delete feature' }
        @{ cmd = 'git push origin 2>/dev/null --delete feature' }
        @{ cmd = 'git push origin <in.txt --delete feature' }
        @{ cmd = 'git push origin --delete feature 2>&1' }
    ) {
        Classify $cmd | Should -Be 'delete'
    }
}

Describe 'text after a separating & is no longer read as the push''s --delete (#546)' {
    It '<cmd>' -ForEach @(
        @{ cmd = 'git push origin mi-rama-normal & echo --delete' }          # the reported case
        @{ cmd = 'git push origin fine & cat --delete' }
        @{ cmd = 'git push origin fine & npm run x --delete' }
        @{ cmd = 'git push origin fine >log.txt & echo --delete' }           # redirect THEN separator
        @{ cmd = 'git push origin fine 2>&1 & echo --delete' }
    ) {
        Classify $cmd | Should -BeNullOrEmpty
    }
    It 'a ; or | before it never mattered (segments are split first) - still allowed' {
        Classify 'git push origin fine ; echo --delete' | Should -BeNullOrEmpty
        Classify 'git push origin fine | tee --delete' | Should -BeNullOrEmpty
    }
}

Describe 'the refspec-delete pattern across a background & (#546, same pass)' {
    It 'text after a separating & is not read as a :refspec' {
        Classify 'git push origin fine & echo x :y' | Should -BeNullOrEmpty
    }
    It 'a real :refspec delete is still denied' {
        Classify 'git push origin :old-branch' | Should -Be 'delete'
        Classify 'git push origin fine & git push origin :old-branch' | Should -Be 'delete'
    }
}

Describe 'the fix only ever REMOVES an over-block' {
    It 'over generated commands, old-denied-but-new-allowed happens ONLY across a separating &' {
        $oldPattern = $script:GitCmd + 'push\b.*--delete\b'
        $newPattern = ($script:BrakePatterns | Where-Object { $_.action -eq 'delete' -and $_.pattern -like '*--delete*' } | Select-Object -First 1).pattern
        $newPattern | Should -Not -BeNullOrEmpty
        $tokens = @('git push origin', 'x', '--delete', 'feat', '&', '2>&1', '>out.txt', '&>o.txt', '<in.txt', 'echo', '&&', ';', '|', '-f', ':y', '--force')
        $rng = New-Object System.Random 546
        $weakened = 0; $checked = 0
        for ($i = 0; $i -lt 6000; $i++) {
            $n = $rng.Next(2, 9)
            $seg = 'git push ' + ((1..$n | ForEach-Object { $tokens[$rng.Next($tokens.Count)] }) -join ' ')
            $norm = ConvertTo-NormalizedCommand $seg
            foreach ($s in ($norm -split $script:SegmentSeparator)) {
                $s = $s.Trim(); if (-not $s) { continue }
                $checked++
                $old = $s -match $oldPattern
                $new = $s -match $newPattern
                if ($new -and -not $old) { throw "NEW pattern denies something OLD allowed: '$s'" }
                if ($old -and -not $new) {
                    # Legitimate only when a SEPARATING & sits between `push` and the last `--delete`.
                    $between = $s.Substring($s.IndexOf('push'))
                    $bare = [regex]::IsMatch($between, '(?<![<>])&(?!>)')
                    if (-not $bare) { throw "NEW pattern lost a deny with no separating &: '$s'" }
                    $weakened++
                }
            }
        }
        $checked | Should -BeGreaterThan 5000
        $weakened | Should -BeGreaterThan 0          # the generator does reach the fixed case
    }
}

Describe 'the classifier stays linear on a hostile command' {
    It '2000 `>&` tokens then a real delete: denied, quickly' {
        $cmd = 'git push origin ' + ('2>&1 ' * 2000) + '--delete feature'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Classify $cmd
        $sw.Stop()
        $r | Should -Be 'delete'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
    It '2000 `>&>` tokens with NO delete: allowed, quickly' {
        $cmd = 'git push origin fine ' + ('>&> ' * 2000) + 'x'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Classify $cmd
        $sw.Stop()
        $r | Should -BeNullOrEmpty
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
}
