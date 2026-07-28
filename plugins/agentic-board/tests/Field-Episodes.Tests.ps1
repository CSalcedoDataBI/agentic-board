#Requires -Modules Pester
<#  Tests for Get-FieldEpisodes.ps1 — stage 2 of /board field (#476).

    Pure core behind $env:ABIOS_FIELDEPISODES_DOTSOURCE. Fixtures are normalized event lists, so
    these pin the SIGNAL LOGIC without depending on the raw transcript schema; a separate test
    covers normalization of real JSONL.

    Every signal is asserted in both directions: it fires when it should, and it does NOT fire on
    the benign shape it most resembles. A detector that only ever says "yes" would pass a
    one-directional suite while making the whole sweep worthless. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-FieldEpisodes.ps1' | Resolve-Path
    $env:ABIOS_FIELDEPISODES_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FIELDEPISODES_DOTSOURCE = ''

    function E {
        param($i, $role, $cmd = '', $err = $false, $text = '')
        [pscustomobject]@{ index = $i; role = $role; command = $cmd; isError = $err; text = $text }
    }
}

Describe 'Get-InvokedTool (what counts as using agentic-board)' {

    It 'recognises a plugin script by name regardless of the path in front of it' {
        Get-InvokedTool -Command 'pwsh -File "C:/long/cache/0.27.0/scripts/Board-Work.ps1" -Sessions' | Should -Be 'Board-Work.ps1'
        Get-InvokedTool -Command 'pwsh plugins/agentic-board/scripts/Expert-Auto.ps1 -Issue 5'        | Should -Be 'Expert-Auto.ps1'
    }

    It 'recognises the typed command surface' {
        Get-InvokedTool -Command '/agentic-board:expert auto 265' | Should -Be '/agentic-board:expert'
        Get-InvokedTool -Command '/board work'                    | Should -Be '/board'
    }

    It 'does not claim unrelated work as tool usage' {
        # A sweep that counts plain gh/git as tool usage would report the tool everywhere.
        Get-InvokedTool -Command 'gh pr create --title x'   | Should -BeNullOrEmpty
        Get-InvokedTool -Command 'git commit -m "board ok"' | Should -BeNullOrEmpty
        Get-InvokedTool -Command 'npm run dashboard'        | Should -BeNullOrEmpty
    }
}

Describe 'Signal: repetition' {

    It 'fires when the same script is invoked again shortly after' {
        $ev = @( (E 0 assistant 'Board-Work.ps1 -Start 5'), (E 1 assistant 'Board-Work.ps1 -Start 5') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Contain 'repetition'
    }

    It 'does not fire for two DIFFERENT scripts in sequence (a normal workflow)' {
        $ev = @( (E 0 assistant 'Expert-Config.ps1'), (E 1 assistant 'Expert-Auto.ps1 -Issue 5') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Not -Contain 'repetition'
    }

    It 'does not fire when the repeat falls outside the window' {
        $ev = @( (E 0 assistant 'Board-Work.ps1'), (E 9 assistant 'Board-Work.ps1') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 3)
        $ep[0].signals | Should -Not -Contain 'repetition'
    }
}

Describe 'Signal: abandonment (the user routed around the tool)' {

    It 'fires when a failed invocation is followed by the same job done with raw gh' {
        $ev = @( (E 0 assistant 'New-BoardPR.ps1 -Issue 5' $true), (E 1 assistant 'gh pr create --title x') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Contain 'abandonment'
    }

    It 'does not fire when the invocation SUCCEEDED and gh was used afterwards anyway' {
        # Following a green run with gh is ordinary work, not abandonment.
        $ev = @( (E 0 assistant 'New-BoardPR.ps1 -Issue 5' $false), (E 1 assistant 'gh pr view 5') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Not -Contain 'abandonment'
    }

    It 'does not fire when a failure is followed by retrying the tool itself' {
        $ev = @( (E 0 assistant 'New-BoardPR.ps1 -Issue 5' $true), (E 1 assistant 'New-BoardPR.ps1 -Issue 5') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Not -Contain 'abandonment'
    }
}

Describe 'Signal: correction' {

    It 'fires when the user negates right after an invocation' {
        $ev = @( (E 0 assistant 'Set-BoardField.ps1 -Field Status -Value Done'), (E 1 user '' $false 'no, eso esta mal, reviertelo') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Contain 'correction'
    }

    It 'does not fire on ordinary approval containing an unrelated negative' {
        # "no" inside "no hay problema" must not read as a correction.
        $ev = @( (E 0 assistant 'Set-BoardField.ps1 -Field Status -Value Done'), (E 1 user '' $false 'perfecto, no hay problema, sigue') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Not -Contain 'correction'
    }
}

Describe 'Signal: silence' {

    It 'fires when the tool is invoked once and nothing follows' {
        $ev = @( (E 0 assistant 'Board-Work.ps1 -Sessions') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Contain 'silence'
    }

    It 'does not fire when the run continued using the tool' {
        $ev = @( (E 0 assistant 'Board-Work.ps1 -Start 5'), (E 1 assistant 'New-BoardPR.ps1 -Issue 5') )
        $ep = @(Get-FieldEpisodes -Events $ev -Window 5)
        $ep[0].signals | Should -Not -Contain 'silence'
    }
}

Describe 'Sweep honesty' {

    It 'reports no episodes for a session that never used the tool' {
        # Most sessions never touch agentic-board. Inventing findings there would poison the sweep.
        $ev = @( (E 0 assistant 'npm test'), (E 1 user '' $false 'gracias') )
        @(Get-FieldEpisodes -Events $ev -Window 5).Count | Should -Be 0
    }

    It 'carries the event index so every episode can be traced back to the transcript' {
        $ev = @( (E 42 assistant 'Board-Work.ps1') )
        (Get-FieldEpisodes -Events $ev -Window 5)[0].index | Should -Be 42
    }
}

Describe 'ConvertTo-FieldEvent + Join-FieldResults (the REAL transcript shape)' {
    <#  These use verbatim JSONL lines, not hand-built objects. The synthetic fixtures above set
        `isError` directly, which hid a real defect: on a real transcript the tool_result arrives in
        its own later event, so the invocation never carried the failure and `abandonment` could
        never fire. Fixtures that assert the logic are not fixtures that assert the parsing. #>

    BeforeAll {
        $script:UseLine = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"pwsh Board-Work.ps1 -Start 5"}}]}}'
        $script:ErrLine = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":"boom"}]}}'
        $script:OkLine  = '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":false,"content":"fine"}]}}'
        $script:GhLine  = '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Bash","input":{"command":"gh pr create --title x"}}]}}'
    }

    It 'pulls the command out of a real tool_use block' {
        $e = ConvertTo-FieldEvent -Line $script:UseLine -Index 0
        $e.role    | Should -Be 'assistant'
        $e.command | Should -Match 'Board-Work\.ps1'
    }

    It 'marks the INVOCATION as failed when the failure arrives in a later separate event' {
        $ev = @(
            (ConvertTo-FieldEvent -Line $script:UseLine -Index 0),
            (ConvertTo-FieldEvent -Line $script:ErrLine -Index 1)
        )
        $linked = @(Join-FieldResults -Events $ev)
        $linked[0].isError | Should -BeTrue   # this is what was silently false before
    }

    It 'does NOT mark the invocation failed when the result succeeded - the other direction' {
        $ev = @(
            (ConvertTo-FieldEvent -Line $script:UseLine -Index 0),
            (ConvertTo-FieldEvent -Line $script:OkLine  -Index 1)
        )
        (@(Join-FieldResults -Events $ev))[0].isError | Should -BeFalse
    }

    It 'attributes a failure only to the invocation it belongs to' {
        $ev = @(
            (ConvertTo-FieldEvent -Line $script:GhLine  -Index 0),
            (ConvertTo-FieldEvent -Line $script:UseLine -Index 1),
            (ConvertTo-FieldEvent -Line $script:ErrLine -Index 2)
        )
        $linked = @(Join-FieldResults -Events $ev)
        $linked[0].isError | Should -BeFalse   # tu_2 did not fail
        $linked[1].isError | Should -BeTrue    # tu_1 did
    }

    It 'yields abandonment end-to-end from real-shaped lines' {
        # The whole point: a failed tool call followed by the job done with bare gh.
        $ev = @(
            (ConvertTo-FieldEvent -Line $script:UseLine -Index 0),
            (ConvertTo-FieldEvent -Line $script:ErrLine -Index 1),
            (ConvertTo-FieldEvent -Line $script:GhLine  -Index 2)
        )
        $ep = @(Get-FieldEpisodes -Events (Join-FieldResults -Events $ev) -Window 5)
        $ep[0].signals | Should -Contain 'abandonment'
    }

    It 'ignores a malformed line instead of inventing a phantom event' {
        ConvertTo-FieldEvent -Line '{not json' -Index 0 | Should -BeNullOrEmpty
    }
}

Describe 'Redaction (nothing leaves the machine unscrubbed)' {

    It 'strips a token-shaped secret from a quoted command' {
        # Assembled from fragments so this line is not itself a contiguous token literal: the
        # repo's pre-commit guard scans added lines, and a test fixture must not trip it. Same
        # technique the guard uses on its own pattern definitions.
        $fake = 'gh' + 'p_' + ('A' * 30) + '012345'
        $r = Protect-FieldText -Text "GH_TOKEN=$fake gh pr list"
        $r | Should -Not -Match $fake
        $r | Should -Match 'REDACTED'
    }

    It 'strips the home-directory leaf that identifies the machine' {
        # Derived from the running account, never hardcoded: a literal username passes only on the
        # machine that wrote it, which is a test that passes for the wrong reason everywhere else.
        $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        $leaf  = Split-Path $home_ -Leaf
        $r = Protect-FieldText -Text "C:\Users\$leaf\Repos\secreto"
        $r | Should -Not -Match ([regex]::Escape($leaf))
        $r | Should -Match '<USER>'
    }

    It 'leaves ordinary text untouched - the other direction' {
        # Over-redaction would make every episode unreadable and the sweep useless.
        $t = 'Board-Work.ps1 -Start 5 failed with exit code 1'
        Protect-FieldText -Text $t | Should -Be $t
    }
}
