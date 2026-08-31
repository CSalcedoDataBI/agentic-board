#Requires -Modules Pester
<#  Tests for Set-BoardField.ps1 - the reads must FAIL CLOSED (#313, part of #303).

    Set-BoardField reads the project id, the field list and the item list up front, then loops
    item-edit writes off them. Two distinct read-then-write hazards, and the tests target the
    ACTUAL failure of each - a naive "gh fails -> Should -Throw" passed even against the un-hardened
    script, because a failed $proj/$fields read already throws downstream via the "field not found"
    guard, for the WRONG reason. So:

      1. The real read-then-write hazard is the ITEM read: a silent failure there leaves $items
         empty, the write loop does nothing, and the script prints a cheerful "set=0 skipped=0
         failed=0" success having read nothing. That path does NOT throw until hardened - this is
         the test that a bare-gh regression fails. gh is mocked per-subcommand: view + field-list
         succeed so we reach the item read, which fails.

      2. The board read hardening is observable in the MESSAGE: without it, a failed board read
         surfaces as a misleading "Field 'Status' not found on project #13"; with it, the error
         names the board read. So the message, not just the throw, is asserted.

    gh is mocked at the executable seam (exit code + body) - the real 401 with no token and no
    network. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Set-BoardField.ps1' | Resolve-Path
    # The script guards on $env:GH_TOKEN before the reads; set a dummy so we exercise the reads,
    # not the token guard. The mock never looks at it.
    $script:PrevToken = $env:GH_TOKEN
    $env:GH_TOKEN = 'dummy'
}
AfterAll {
    $env:GH_TOKEN = $script:PrevToken
}

Describe 'Set-BoardField fails closed on a failed read (#313)' {

    It 'THROWS on a failed item read instead of reporting a false "set=0" success' {
        # view + field-list succeed so the script reaches the item read; the item read then fails.
        Mock gh -ParameterFilter { $args -contains 'view' }       { $global:LASTEXITCODE = 0; '{"id":"PVT_1"}' }
        Mock gh -ParameterFilter { $args -contains 'field-list' }  { $global:LASTEXITCODE = 0; '{"fields":[{"name":"Status","id":"F1","options":[{"name":"Done","id":"o1"}]}]}' }
        Mock gh -ParameterFilter { $args -contains 'item-list' }   { $global:LASTEXITCODE = 1 }
        { & $script:Script -Number 13 -Owner 'X' -Field 'Status' -Value 'Done' } | Should -Throw
        # The write must never run off a read that failed.
        Should -Invoke gh -ParameterFilter { $args -contains 'item-edit' } -Times 0 -Exactly
    }

    It 'names the board read in the error, not a misleading "field not found", when the board read fails' {
        # Both board reads fail. Un-hardened, both $proj and $fields come back empty, $fdef is
        # null, and the script throws the misleading "Field 'Status' not found on project #13".
        # Hardened, the FIRST board read throws naming the board. Mock both (no real-gh fallthrough)
        # so the assertion is deterministic.
        Mock gh -ParameterFilter { $args -contains 'view' }       { $global:LASTEXITCODE = 1 }
        Mock gh -ParameterFilter { $args -contains 'field-list' }  { $global:LASTEXITCODE = 1 }
        { & $script:Script -Number 13 -Owner 'X' -Field 'Status' -Value 'Done' } |
            Should -Throw -ExpectedMessage '*board #13*'
    }
}
