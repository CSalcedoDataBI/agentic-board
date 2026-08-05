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

Describe 'Regression: every board item read must go through the shared reader' {
    <#  The narrow version of this test banned the literal `'--limit', '200'` and nothing else — it
        would have passed on `--limit 200` unquoted, on a variable defaulting to 200, and on all the
        500/800/1000 readers that were STILL asserting absences when this was first written (one of
        them gating a destructive option delete). The invariant worth pinning is not "not 200", it is
        "no script hardcodes its own item-list cap": every board read either goes through
        Get-BoardItems or asks Get-BoardItemReadLimit for the shared ceiling. #>

    BeforeDiscovery {
        $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts'
        # Get-BoardItems itself is where the one legitimate item-list call lives.
        $script:ReaderFile = 'Get-BoardItems.ps1'
    }

    It 'no script hardcodes a numeric --limit on gh project item-list' {
        $offenders = @()
        foreach ($s in (Get-ChildItem $script:ScriptDir -Filter '*.ps1')) {
            if ($s.Name -eq $script:ReaderFile) { continue }
            $text = Get-Content $s.FullName -Raw
            if ($text -notmatch 'item-list') { continue }
            # Any literal digit run following --limit, quoted or not, single or double.
            if ($text -match "--limit'?\s*,?\s*[`"']?\d") { $offenders += $s.Name }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty
    }

    It 'every script that reads board items pulls in the shared reader' {
        $missing = @()
        foreach ($s in (Get-ChildItem $script:ScriptDir -Filter '*.ps1')) {
            if ($s.Name -eq $script:ReaderFile) { continue }
            $text = Get-Content $s.FullName -Raw
            if ($text -notmatch 'item-list') { continue }
            if ($text -notmatch 'Get-BoardItems\.ps1') { $missing += $s.Name }
        }
        $missing -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Regression: no caller may state an absence off a possibly-short read' {
    <#  The user-visible half of the bug: each of these files prints a sentence asserting that
        nothing is there, and each must consult the truncation flag before doing so.

        These are COARSE checks — presence of the guard in the same file, not proof that it wraps
        the right branch. That limit is deliberate: the first version of this block matched the
        DISTANCE between the guard and the message, which broke the moment a branch grew a line and
        would have trained the next reader to loosen the assertion rather than fix the code. Branch
        placement is covered by the helper's own behavioural tests above plus the live check on the
        291-item board; what these add is "nobody deleted the guard". #>

    It 'Board-Work consults the truncation flag before its "Sin pendientes"' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1') -Raw
        $t | Should -Match 'Sin pendientes'          # the all-clear still exists...
        $t | Should -Match 'if \(\$truncWarn\)'      # ...and so does the guard on it
    }
    It 'Board-Triage consults it before its "(no hay items pendientes)"' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Triage.ps1') -Raw
        $t | Should -Match 'no hay items pendientes'
        $t | Should -Match 'if \(\$itemTrunc\)'
    }
    It 'Assert-BoardComplete refuses to PASS on a truncated read' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Assert-BoardComplete.ps1') -Raw
        $t | Should -Match '\$truncWarn -and \$result\.Complete'
    }
    It 'Apply-FieldPreset refuses to DELETE an option verified by a truncated read' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Apply-FieldPreset.ps1') -Raw
        $t | Should -Match '\$postRead\.Truncated'
    }
    It 'Backup-Board refuses to write a partial snapshot' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Backup-Board.ps1') -Raw
        $t | Should -Match 'un backup parcial no es un backup'
    }
    It 'Export-BoardSnapshot refuses to publish a truncated "N of M"' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Export-BoardSnapshot.ps1') -Raw
        $t | Should -Match '\$items\.Count -ge \$itemLimit'
    }
    It 'Set-BoardField does not exit 0 after a partial sweep' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Set-BoardField.ps1') -Raw
        $t | Should -Match 'if \(\$itemRead\.Truncated\) \{ exit 1 \}'
    }
    It 'Assert-BoardComplete reports truncated on every -Json response, not just the fail-closed one' {
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Assert-BoardComplete.ps1') -Raw
        # Two emitters: the fail-closed branch and the normal one. BOTH must carry the field, or a
        # consumer reads a floor as an exact count on the path that still found pending items.
        @([regex]::Matches($t, 'truncated\s*=')).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Regression: a wrapper return value must never be counted as one item' {
    <#  This one exists because the fix ITSELF shipped this bug and the suite missed it.

        Get-ItemsOnOption used to return a bare array; making it report truncation turned it into
        { Items; Truncated }. Two of its three call sites were updated. The third was
        `@(Get-ItemsOnOption ...).Count`, which counts the WRAPPER — so it reported "1 item(s)" for
        every merge, on the pre-confirmation line whose only job is telling the user how many items
        a destructive delete is about to move. Every test still passed: the suite covered the
        helper's shape and the guard's presence, never a caller's arithmetic.

        `@(<object>).Count -eq 1` is silent, plausible, and PowerShell-specific, so it is pinned by
        shape rather than left to the next reader to remember. #>

    It 'no call site wraps Get-ItemsOnOption in @() and counts it' {
        # VERIFIED to fail on the real defect: the bug was reintroduced in the source and this
        # assertion went red, which is the only reason it is trusted. A companion check that
        # merely counted `.Items` occurrences file-wide stayed GREEN with the bug present and was
        # deleted rather than kept as decoration.
        $t = Get-Content (Join-Path $PSScriptRoot '..' 'scripts' 'Apply-FieldPreset.ps1') -Raw
        $t | Should -Not -Match '@\(Get-ItemsOnOption'
    }
}
