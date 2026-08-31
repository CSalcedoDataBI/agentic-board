#Requires -Modules Pester
<#  Tests for Post-BoardStatusUpdate.ps1 - reads must FAIL CLOSED (#315, part of #303).

    The write here is a public status update posted to the board. Two hazards:

      1. The auto-generated body is built from `gh project item-list`. A silent failure there
         leaves $items empty and the script posts "0 Done / 0 In Progress / 0 Backlog (0 items)"
         as if the board were empty. This is the read-then-write bug: the misread drives the post.
         Test 1 mocks the project-id read to succeed, then fails the item read, and asserts the
         status-update mutation NEVER runs.

      2. The project-id read is a `gh api graphql` call. It already fails closed via the
         `if (-not $projectId)` guard, but on an exit-0 errors[] body that guard reports a
         misleading "Board #13 no encontrado". -Graphql now names the actual read failure.
         Test 2 pins that via the message (the throw alone does not distinguish the two).

    gh is mocked at the executable seam. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Post-BoardStatusUpdate.ps1' | Resolve-Path
    $script:PrevToken = $env:GH_TOKEN
    $env:GH_TOKEN = 'dummy'
}
AfterAll {
    $env:GH_TOKEN = $script:PrevToken
}

Describe 'Post-BoardStatusUpdate fails closed (#315)' {

    It 'THROWS naming the item read (not posting) when the board item read fails' {
        # project-id read succeeds so we reach the body-building item read, which then fails.
        # Asserted via the MESSAGE, not a bare throw: un-hardened, a failed item read yields empty
        # $items and either posts a "0 items" body or dies with an unrelated ConvertFrom-Json error -
        # neither names the item read, so the ExpectedMessage below rejects the un-hardened script
        # (a bare `Should -Throw` passed against it, the same wrong-reason pass seen elsewhere).
        Mock gh -ParameterFilter { ($args -join ' ') -match 'projectV2\(number' } { $global:LASTEXITCODE = 0; '{"data":{"user":{"projectV2":{"id":"PID_1","title":"B"}}}}' }
        Mock gh -ParameterFilter { $args -contains 'item-list' } { $global:LASTEXITCODE = 1 }
        # No -Body, so the body is auto-generated from the item read.
        { & $script:Script -ProjectNum 13 } | Should -Throw -ExpectedMessage '*listar los items*'
        # And the public post must never run off a board it could not read.
        Should -Invoke gh -ParameterFilter { ($args -join ' ') -match 'createProjectV2StatusUpdate' } -Times 0 -Exactly
    }

    It 'names the graphql read failure, not a misleading "board not found", on an errors[] body' {
        Mock gh -ParameterFilter { ($args -join ' ') -match 'projectV2\(number' } { $global:LASTEXITCODE = 0; '{"data":null,"errors":[{"message":"Could not resolve"}]}' }
        # -Body given so the item read is skipped; the project-id read is what must throw.
        { & $script:Script -ProjectNum 13 -Body 'manual body' } |
            Should -Throw -ExpectedMessage '*leer el board*'
    }
}
