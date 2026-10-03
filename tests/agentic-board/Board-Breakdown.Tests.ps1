#Requires -Modules Pester
<#  Tests for Board-Breakdown.ps1 - addSubIssue must FAIL CLOSED on errors[] (#315, part of #303).

    addSubIssue is a `gh api graphql` mutation. The old code piped it to Out-Null and only checked
    $LASTEXITCODE - but graphql can return exit 0 WITH an errors[] body (already-linked, permissions),
    so a child that never got linked was still printed "OK  #n" and listed as a sub-issue. -Graphql
    throws on the errors[] body, so the child is reported as a FAIL that needs manual linking.

    Board-Breakdown catches per-task (it keeps going through the rest), so the observable is the
    OUTPUT: a failed link prints "FAIL", never "OK  #n". gh is mocked per-subcommand at the seam so
    every step up to addSubIssue succeeds and only the link returns errors[]. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Breakdown.ps1' | Resolve-Path
    $script:PrevToken = $env:GH_TOKEN
    $env:GH_TOKEN = 'dummy'
}
AfterAll {
    $env:GH_TOKEN = $script:PrevToken
}

Describe 'Board-Breakdown fails closed on an addSubIssue errors[] body (#315)' {

    It 'reports the child as FAIL (not OK) when addSubIssue returns errors[] despite exit 0' {
        # Parent read (Invoke-Gh -Json): open issue.
        Mock gh -ParameterFilter { ($args -join ' ') -match 'id,title,state' }            { $global:LASTEXITCODE = 0; '{"id":"PARENT","title":"P","state":"OPEN"}' }
        # Label ensure (no 'issue' in args) - succeeds silently.
        Mock gh -ParameterFilter { ($args -contains 'label') -and -not ($args -contains 'issue') } { $global:LASTEXITCODE = 0 }
        # Child issue create - returns its URL.
        Mock gh -ParameterFilter { ($args -contains 'issue') -and ($args -contains 'create') }  { $global:LASTEXITCODE = 0; 'https://github.com/o/r/issues/101' }
        # Child id lookup (uses -q .id).
        Mock gh -ParameterFilter { $args -contains '-q' }                                   { $global:LASTEXITCODE = 0; 'CHILD_ID' }
        # addSubIssue: HTTP 200 but the query failed.
        Mock gh -ParameterFilter { $args -contains 'graphql' }                              { $global:LASTEXITCODE = 0; '{"data":null,"errors":[{"message":"could not add sub-issue"}]}' }

        $out = & $script:Script -Parent 13 -Tasks 'Task A' -Repo 'o/r' *>&1 | Out-String
        $out | Should -Match 'FAIL'
        $out | Should -Not -Match 'OK  #'
    }
}
