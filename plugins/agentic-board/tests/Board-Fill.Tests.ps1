#Requires -Modules Pester
<#  Pester tests for Board-Fill.ps1 - the /board fill gap-filler.

    Board-Fill.ps1 is a side-effecting command (gh + Write-Host), so it exposes a
    dot-source guard: with $env:ABIOS_BOARDFILL_DOTSOURCE set, it returns after
    defining every function WITHOUT the token check or any gh call. That lets us
    unit-test the pure owner-resolution helpers, which encode the decision behind
    issue #86 (a board owner may be a USER or an ORGANIZATION). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Fill.ps1' | Resolve-Path
    $env:ABIOS_BOARDFILL_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDFILL_DOTSOURCE = ''
}

Describe 'Get-OwnerRoot (owner-type -> GraphQL root, issue #86)' {
    It 'maps a User owner to the user() root' {
        Get-OwnerRoot -OwnerType 'User' | Should -Be 'user'
    }
    It 'maps an Organization owner to the organization() root' {
        Get-OwnerRoot -OwnerType 'Organization' | Should -Be 'organization'
    }
    It 'returns $null for an unknown / unresolved owner type' {
        Get-OwnerRoot -OwnerType $null   | Should -BeNullOrEmpty
        Get-OwnerRoot -OwnerType 'Bot'   | Should -BeNullOrEmpty
        Get-OwnerRoot -OwnerType ''      | Should -BeNullOrEmpty
    }
}

Describe 'Get-BoardItems fails closed on a gh failure (#313, part of #303)' {
    # Board-Fill dot-sources Invoke-Gh BEFORE its guard, so dot-sourcing the script above also
    # defines the Invoke-GhRaw seam - mocking it reproduces any exit code / body with no token
    # and no network. Before #313 a gh failure mid-scan returned an EMPTY page and the gap
    # detector reported a healthy "no gaps" board it had never read (the #86 false-clean).
    It 'THROWS when the item read exits non-zero instead of returning an empty page' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Get-BoardItems 'PVT_x' } | Should -Throw
    }
    It 'THROWS on a graphql errors[] body despite exit 0 (the read succeeded, the query did not)' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"Could not resolve to a node"}]}'; ExitCode = 0; StdErr = '' } }
        { Get-BoardItems 'PVT_x' } | Should -Throw
    }
    It 'returns the page nodes when the read succeeds - an empty board is not an error' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"i1"},{"id":"i2"}]}}}}'; ExitCode = 0; StdErr = '' } }
        @(Get-BoardItems 'PVT_x').Count | Should -Be 2
    }
    It 'passes the page-2 cursor as a -f variable, never spliced into the query as after: "..." (#329)' {
        # A board >100 items needs a 2nd page. Interpolating after: "$cursor" put embedded quotes
        # into a native gh.exe arg, which PowerShell drops, so gh saw the base64 cursor unquoted
        # and its `==` padding broke the query. The cursor now rides as a GraphQL variable instead.
        # Page chosen by CALL COUNT, not arg content, so a regression that still paginates
        # terminates and fails on the assertions rather than looping forever.
        $script:pgCalls = @(); $script:pgN = 0
        Mock Invoke-GhRaw {
            $script:pgCalls += ,@($GhArgs); $script:pgN++
            if ($script:pgN -ge 2) {
                [pscustomobject]@{ Output = '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"i2"}]}}}}'; ExitCode = 0; StdErr = '' }
            } else {
                [pscustomobject]@{ Output = '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR=="},"nodes":[{"id":"i1"}]}}}}'; ExitCode = 0; StdErr = '' }
            }
        }
        $nodes = @(Get-BoardItems 'PVT_x')
        $nodes.Count         | Should -Be 2             # both pages accumulated
        $script:pgCalls.Count | Should -Be 2
        (@($script:pgCalls[1]) -contains 'cursor=CUR==') | Should -BeTrue
        foreach ($c in $script:pgCalls) {
            $qArg = @($c) | Where-Object { $_ -like 'query=*' }
            $qArg | Should -Not -Match 'after:\s*"'
            $qArg | Should -Match 'after:\$cursor'
        }
    }
}

Describe 'Convert-DraftToIssue fails closed on a graphql errors[] body (#315)' {
    # convertProjectV2DraftIssueItemToIssue can 200 with an errors[] body. Before #315 that parsed
    # to a $null number and the draft was still COUNTED as converted - "converted" reported for a
    # note that is still a draft. -Graphql throws on errors[] so the caller records a FAIL instead.
    It 'THROWS on an exit-0 errors[] body instead of returning a $null number' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"repo not writable"}]}'; ExitCode = 0; StdErr = '' } }
        { Convert-DraftToIssue 'DRAFT_1' 'REPO_1' 'my draft' } | Should -Throw
    }
    It 'returns the new issue number on success' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"convertProjectV2DraftIssueItemToIssue":{"item":{"content":{"number":42}}}}}'; ExitCode = 0; StdErr = '' } }
        Convert-DraftToIssue 'DRAFT_1' 'REPO_1' 'my draft' | Should -Be 42
    }
}

Describe 'Set-ItemSingleSelectValue fails closed on a graphql errors[] body (#315)' {
    # The core gap-fill write: updateProjectV2ItemFieldValue can 200 with an errors[] body (a stale
    # option id, a field-scoped permission). Before #315 that was piped to Out-Null with no check,
    # so the run printed "OK  #n Status -> Backlog" and counted it while the field stayed empty.
    # -Graphql throws so the caller records a FAIL instead of a false OK.
    It 'THROWS on an exit-0 errors[] body instead of silently succeeding' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"updateProjectV2ItemFieldValue":null},"errors":[{"message":"stale option id"}]}'; ExitCode = 0; StdErr = '' } }
        { Set-ItemSingleSelectValue 'PVT_1' 'ITEM_1' 'FIELD_1' 'OPT_1' } | Should -Throw
    }
    It 'does not throw when the write succeeds' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"ITEM_1"}}}}'; ExitCode = 0; StdErr = '' } }
        { Set-ItemSingleSelectValue 'PVT_1' 'ITEM_1' 'FIELD_1' 'OPT_1' } | Should -Not -Throw
    }
}

Describe 'Get-AllPages (board pagination - issue #246)' {
    It 'concatenates nodes across pages and stops when hasNext is false' {
        $script:calls = 0
        $fetch = {
            param($cursor)
            $script:calls++
            if ($script:calls -eq 1) { @{ nodes = @(1,2); hasNext = $true;  endCursor = 'c1' } }
            else                     { @{ nodes = @(3);   hasNext = $false; endCursor = $null } }
        }
        (Get-AllPages $fetch) | Should -Be @(1,2,3)
        $script:calls | Should -Be 2
    }
    It 'returns an empty array for a single empty page' {
        @(Get-AllPages { param($c) @{ nodes = @(); hasNext = $false; endCursor = $null } }).Count | Should -Be 0
    }
}

Describe 'Get-OwnerUrlSegment (projects URL segment)' {
    It 'uses /orgs/ for an organization' {
        Get-OwnerUrlSegment -OwnerType 'Organization' | Should -Be 'orgs'
    }
    It 'uses /users/ for a user' {
        Get-OwnerUrlSegment -OwnerType 'User' | Should -Be 'users'
    }
    It 'defaults to /users/ when the owner type is unknown' {
        Get-OwnerUrlSegment -OwnerType $null | Should -Be 'users'
        Get-OwnerUrlSegment -OwnerType ''    | Should -Be 'users'
    }
}

Describe 'Resolve-Opt (canonical option with legacy fallback, issue #278)' {
    BeforeAll {
        # Shaped like the GraphQL single-select field node Board-Fill resolves options from.
        $script:CanonStatus = [pscustomobject]@{ id = 'F1'; options = @(
            [pscustomobject]@{ id = 'c1'; name = 'Backlog' }
            [pscustomobject]@{ id = 'c2'; name = 'In Progress' }
        ) }
        $script:LegacyStatus = [pscustomobject]@{ id = 'F2'; options = @(
            [pscustomobject]@{ id = 'l1'; name = 'Todo' }
            [pscustomobject]@{ id = 'l2'; name = 'In Progress' }
        ) }
        $script:CanonPrio = [pscustomobject]@{ id = 'F3'; options = @(
            [pscustomobject]@{ id = 'p2'; name = 'P2' }
        ) }
        $script:LegacyPrio = [pscustomobject]@{ id = 'F4'; options = @(
            [pscustomobject]@{ id = 'q2'; name = 'P2 Medium' }
        ) }
    }
    It 'resolves the canonical name on a canonical board' {
        (Resolve-Opt $script:CanonStatus 'Status' 'Backlog').id | Should -Be 'c1'
    }
    It "resolves Backlog to a default-template board's 'Todo'" {
        $o = Resolve-Opt $script:LegacyStatus 'Status' 'Backlog'
        $o.id   | Should -Be 'l1'
        $o.name | Should -Be 'Todo'
    }
    It "fills Priority on the tool's OWN board - the P2/'P2 Medium' mismatch of #278" {
        (Resolve-Opt $script:CanonPrio  'Priority' 'P2').id | Should -Be 'p2'
        (Resolve-Opt $script:LegacyPrio 'Priority' 'P2').id | Should -Be 'q2'
    }
    It 'prefers the canonical name when a board carries both vocabularies' {
        $both = [pscustomobject]@{ options = @(
            [pscustomobject]@{ id = 'l1'; name = 'Todo' }
            [pscustomobject]@{ id = 'c1'; name = 'Backlog' }
        ) }
        (Resolve-Opt $both 'Status' 'Backlog').id | Should -Be 'c1'
    }
    It 'returns $null when the option is absent, so the caller skips that fill' {
        Resolve-Opt $script:CanonStatus 'Status' 'In Review' | Should -BeNullOrEmpty
    }
    It 'returns $null for a field the board does not have at all' {
        Resolve-Opt $null 'Size' 'M' | Should -BeNullOrEmpty
    }
}
