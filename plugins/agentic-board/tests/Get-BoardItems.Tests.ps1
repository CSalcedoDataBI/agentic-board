#Requires -Modules Pester
<#  Tests for Get-BoardItems.ps1 — the board read that reports its own truncation (#484).

    The bug being pinned here is not an off-by-N. `gh project item-list --limit 200` returns exit 0
    and exactly 200 items on a bigger board, oldest-first, so the Backlog falls off the end and the
    caller prints "Sin pendientes" over a board full of open work. The read SUCCEEDS at lying.

    So two things must hold, and the pair is the contract:
      * a read under the cap is complete           -> Truncated $false, callers may assert an absence.
      * a read that reaches the cap is suspect     -> Truncated $true, callers may NOT.
    If those ever collapse into each other the helper has failed at its only job.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Get-BoardItems.ps1')

    # N items shaped like `gh project item-list --format json` emits them.
    function script:Items([int]$n) {
        1..$n | ForEach-Object { [pscustomobject]@{ content = [pscustomobject]@{ number = $_ }; status = 'Done' } }
    }
}

Describe 'Get-BoardItems — a complete read' {
    BeforeEach {
        Mock Invoke-Gh { [pscustomobject]@{ items = @(script:Items 291) } }
    }
    It 'returns every item it read' {
        (Get-BoardItems -Number 13 -Owner x).Read | Should -Be 291
    }
    It 'is NOT truncated when the read came back under the cap' {
        (Get-BoardItems -Number 13 -Owner x).Truncated | Should -BeFalse
    }
    It 'hands back the items themselves, not just a count' {
        @((Get-BoardItems -Number 13 -Owner x).Items).Count | Should -Be 291
    }
}

Describe 'Get-BoardItems — a capped read is truncated, not complete' {
    It 'flags a read that came back at exactly the cap' {
        Mock Invoke-Gh { [pscustomobject]@{ items = @(script:Items 50) } }
        $r = Get-BoardItems -Number 13 -Owner x -Limit 50
        $r.Truncated | Should -BeTrue
        $r.Read      | Should -Be 50
    }
    It 'flags it even when the board holds EXACTLY the cap — a false alarm is cheaper than a false all-clear' {
        Mock Invoke-Gh { [pscustomobject]@{ items = @(script:Items 10) } }
        (Get-BoardItems -Number 13 -Owner x -Limit 10).Truncated | Should -BeTrue
    }
    It 'the 291-item board that shipped the bug is NOT truncated at the new default' {
        Mock Invoke-Gh { [pscustomobject]@{ items = @(script:Items 291) } }
        (Get-BoardItems -Number 13 -Owner x).Truncated | Should -BeFalse
    }
}

Describe 'Get-BoardItems — an empty board is empty, not broken' {
    It 'reads 0 items without claiming truncation' {
        Mock Invoke-Gh { [pscustomobject]@{ items = @() } }
        $r = Get-BoardItems -Number 13 -Owner x
        $r.Read      | Should -Be 0
        $r.Truncated | Should -BeFalse
    }
    It 'survives gh returning $null for an empty array (ConvertFrom-Json emits nothing for [])' {
        Mock Invoke-Gh { [pscustomobject]@{ items = $null } }
        (Get-BoardItems -Number 13 -Owner x).Read | Should -Be 0
    }
}

Describe 'Get-BoardItems — the cap it actually sends to gh' {
    BeforeEach {
        $script:sent = $null
        Mock Invoke-Gh { $script:sent = $GhArgs; [pscustomobject]@{ items = @(script:Items 5) } }
    }
    It 'defaults well past 200 — the cap that produced the false all-clear' {
        $null = Get-BoardItems -Number 13 -Owner x
        $i = [array]::IndexOf($script:sent, '--limit')
        $i | Should -BeGreaterThan -1
        [int]$script:sent[$i + 1] | Should -BeGreaterOrEqual 1000
    }
    It 'asks gh for the board and owner it was given' {
        $null = Get-BoardItems -Number 13 -Owner CSalcedoDataBI
        $script:sent | Should -Contain 'item-list'
        $script:sent | Should -Contain '13'
        $script:sent | Should -Contain 'CSalcedoDataBI'
    }
    It 'honors an explicit -Limit' {
        $null = Get-BoardItems -Number 13 -Owner x -Limit 777
        $i = [array]::IndexOf($script:sent, '--limit')
        $script:sent[$i + 1] | Should -Be '777'
    }
}

Describe 'Get-BoardItems — a failed read still throws (Invoke-Gh contract preserved)' {
    It 'does not swallow a gh failure into an empty, complete-looking read' {
        Mock Invoke-Gh { throw 'No pude listar los items (gh exit 1): HTTP 401' }
        { Get-BoardItems -Number 13 -Owner x } | Should -Throw
    }
}

Describe 'Get-BoardTruncationWarning' {
    It 'is silent on a complete read — nothing to warn about' {
        Get-BoardTruncationWarning ([pscustomobject]@{ Truncated = $false; Read = 291; Limit = 2000 }) |
            Should -BeNullOrEmpty
    }
    It 'names how many items it actually read, so the number is auditable' {
        $w = Get-BoardTruncationWarning ([pscustomobject]@{ Truncated = $true; Read = 200; Limit = 200 })
        $w | Should -Match 'TRUNCADO'
        $w | Should -Match '200'
    }
    It 'refuses to assert an absence — the whole point of the flag' {
        $w = Get-BoardTruncationWarning ([pscustomobject]@{ Truncated = $true; Read = 200; Limit = 200 })
        $w | Should -Match 'NO puedo afirmar'
    }
}

Describe 'Regression: no board read may go back to a 200-item cap' {
    <#  The bug was one literal in two call sites. Scripts read boards for different reasons, but
        NONE of them may cap at 200 again — this asserts it across the whole script directory rather
        than trusting that the next reader remembers why. #>
    It 'no script asks gh project item-list with --limit 200' {
        $scripts = Get-ChildItem (Join-Path $PSScriptRoot '..' 'scripts') -Filter '*.ps1'
        $bad = @()
        foreach ($s in $scripts) {
            $text = Get-Content $s.FullName -Raw
            if ($text -match "item-list" -and $text -match "'--limit'\s*,\s*'200'") { $bad += $s.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty
    }
}
