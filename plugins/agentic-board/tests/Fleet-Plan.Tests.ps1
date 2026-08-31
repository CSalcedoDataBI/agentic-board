#Requires -Modules Pester
<#  Pester tests for Fleet-Plan.ps1 - the advisory board-lead planner (P3-2). It reads
    pending board issues and emits an assignment map (issue -> CLI -> dependency wave)
    WITHOUT launching anything. Side-effecting at the edges (gh), so a dot-source guard
    ($env:ABIOS_FLEETPLAN_DOTSOURCE) exposes the pure planner core for unit tests. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Plan.ps1' | Resolve-Path
    $env:ABIOS_FLEETPLAN_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FLEETPLAN_DOTSOURCE = ''

    function New-Iss {
        param([int]$Number, [string]$Title = 't', [string[]]$Labels = @(), [string]$Size = 'M', [string]$Type = 'Feature', [int[]]$BlockedBy = @())
        [pscustomobject]@{ number = $Number; title = $Title; labels = $Labels; size = $Size; type = $Type; blockedBy = $BlockedBy }
    }
    $all = @('claude','codex','antigravity','copilot')
}

Describe 'Get-PendingBoardIssues fails closed on the board read (#316, part of #303)' {
    # Fleet-Plan dot-sources Invoke-Gh before its guard, so the Invoke-GhRaw seam is defined here.
    # A failed board read used to yield $null -> an EMPTY plan written to the ledger as "nothing
    # pending" (the #86 class: a misread driving a wrong write). -Graphql now throws instead.
    It 'THROWS on a non-zero exit instead of returning an empty (no-pending) plan' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
        { Get-PendingBoardIssues 'owner' 13 } | Should -Throw
    }
    It 'THROWS on a graphql errors[] body despite exit 0' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"boom"}]}'; ExitCode = 0; StdErr = '' } }
        { Get-PendingBoardIssues 'owner' 13 } | Should -Throw
    }
    It 'returns empty (no throw) for a successfully-read board with nothing pending' {
        # One CLOSED issue -> filtered out before the per-issue blocked_by read, so no real gh call.
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"user":{"projectV2":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"fieldValues":{"nodes":[]},"content":{"__typename":"Issue","number":9,"state":"CLOSED","title":"done","repository":{"nameWithOwner":"o/r"},"labels":{"nodes":[]}}}]}}}}}'; ExitCode = 0; StdErr = '' } }
        @(Get-PendingBoardIssues 'owner' 13).Count | Should -Be 0
    }
    It 'passes the page-2 cursor as a -f variable, never spliced into the query as after: "..." (#329)' {
        # A board >100 items needs a 2nd page. Interpolating after: "$cursor" put embedded quotes into
        # a native gh.exe arg, which PowerShell drops, so gh saw the base64 cursor unquoted and its
        # `==` broke the query. Both pages use CLOSED issues so the blocked_by REST path never runs.
        # Page chosen by CALL COUNT, not arg content, so a regression that still paginates
        # terminates and fails on the assertions rather than looping forever.
        $script:pgCalls = @(); $script:pgN = 0
        Mock Invoke-GhRaw {
            $script:pgCalls += ,@($GhArgs); $script:pgN++
            $closed = '{"fieldValues":{"nodes":[]},"content":{"__typename":"Issue","number":9,"state":"CLOSED","title":"done","repository":{"nameWithOwner":"o/r"},"labels":{"nodes":[]}}}'
            if ($script:pgN -ge 2) {
                [pscustomobject]@{ Output = "{`"data`":{`"user`":{`"projectV2`":{`"items`":{`"pageInfo`":{`"hasNextPage`":false,`"endCursor`":null},`"nodes`":[$closed]}}}}}"; ExitCode = 0; StdErr = '' }
            } else {
                [pscustomobject]@{ Output = "{`"data`":{`"user`":{`"projectV2`":{`"items`":{`"pageInfo`":{`"hasNextPage`":true,`"endCursor`":`"CUR==`"},`"nodes`":[$closed]}}}}}"; ExitCode = 0; StdErr = '' }
            }
        }
        $null = Get-PendingBoardIssues 'owner' 13
        $script:pgCalls.Count | Should -Be 2
        (@($script:pgCalls[1]) -contains 'cursor=CUR==') | Should -BeTrue
        foreach ($c in $script:pgCalls) {
            $qArg = @($c) | Where-Object { $_ -like 'query=*' }
            $qArg | Should -Not -Match 'after:\s*"'
            $qArg | Should -Match 'after:\$cursor'
        }
    }
}

Describe 'Select-CliForIssue (capability routing with availability fallback)' {
    It 'routes security/architecture/large work to claude' {
        Select-CliForIssue (New-Iss 1 -Labels 'security') $all | Should -Be 'claude'
        Select-CliForIssue (New-Iss 2 -Size 'L')          $all | Should -Be 'claude'
    }
    It 'routes refactors to codex when available' {
        Select-CliForIssue (New-Iss 3 -Type 'Refactor') $all | Should -Be 'codex'
    }
    It 'falls back to claude when the preferred CLI is not available' {
        Select-CliForIssue (New-Iss 4 -Type 'Refactor') @('claude','antigravity') | Should -Be 'claude'
    }
    It 'routes docs to antigravity' {
        Select-CliForIssue (New-Iss 5 -Type 'Docs') @('antigravity','claude') | Should -Be 'antigravity'
    }
    It 'routes small chores to copilot, then antigravity' {
        Select-CliForIssue (New-Iss 6 -Type 'Chore' -Size 'S') @('copilot','claude') | Should -Be 'copilot'
        Select-CliForIssue (New-Iss 6 -Type 'Chore' -Size 'S') @('antigravity','claude') | Should -Be 'antigravity'
    }
    It 'never routes to the retired gemini CLI, even when offered (#615)' {
        # The whole point of #615: gemini can no longer authenticate, so it must not be a
        # preference any more - offering it must not beat claude.
        Select-CliForIssue (New-Iss 9 -Type 'Docs')  @('gemini','claude') | Should -Be 'claude'
        Select-CliForIssue (New-Iss 10 -Type 'Chore' -Size 'XS') @('gemini','claude') | Should -Be 'claude'
    }
    It 'defaults a plain feature to claude' {
        Select-CliForIssue (New-Iss 7) $all | Should -Be 'claude'
    }
    It 'uses the first available CLI when nothing preferred (not even claude) is present' {
        Select-CliForIssue (New-Iss 8 -Type 'Docs') @('copilot') | Should -Be 'copilot'
    }
}

Describe 'Get-AssignmentWaves (dependency-aware layering)' {
    It 'puts fully-independent issues in a single wave' {
        $w = Get-AssignmentWaves @( (New-Iss 1), (New-Iss 2), (New-Iss 3) )
        $w.Count | Should -Be 1
        @($w[0]).Count | Should -Be 3
    }
    It 'sequences a blocker before its dependent' {
        $w = Get-AssignmentWaves @( (New-Iss 1), (New-Iss 2 -BlockedBy 1) )
        $w.Count | Should -Be 2
        $w[0][0].number | Should -Be 1
        $w[1][0].number | Should -Be 2
    }
    It 'builds one wave per link in a chain A->B->C' {
        $w = Get-AssignmentWaves @( (New-Iss 1), (New-Iss 2 -BlockedBy 1), (New-Iss 3 -BlockedBy 2) )
        $w.Count | Should -Be 3
    }
    It 'treats a blocker OUTSIDE the pending set as already satisfied' {
        $w = Get-AssignmentWaves @( (New-Iss 5 -BlockedBy 99) )   # 99 not in the set
        $w.Count | Should -Be 1
        $w[0][0].number | Should -Be 5
    }
    It 'does not hang on a dependency cycle (places the rest in a final wave)' {
        $w = Get-AssignmentWaves @( (New-Iss 1 -BlockedBy 2), (New-Iss 2 -BlockedBy 1) )
        @($w | ForEach-Object { $_ }).Count | Should -BeGreaterThan 0
        # both issues still appear somewhere
        (@($w | ForEach-Object { $_ }) | ForEach-Object { $_.number } | Sort-Object) | Should -Be @(1,2)
    }
}

Describe 'New-AssignmentPlan (waves x routing)' {
    It 'assigns every issue a wave and a CLI' {
        $plan = New-AssignmentPlan @( (New-Iss 1 -Type 'Refactor'), (New-Iss 2 -BlockedBy 1 -Labels 'security') ) @('claude','codex')
        ($plan | Where-Object { $_.issue -eq 1 }).wave | Should -Be 1
        ($plan | Where-Object { $_.issue -eq 1 }).cli  | Should -Be 'codex'
        ($plan | Where-Object { $_.issue -eq 2 }).wave | Should -Be 2
        ($plan | Where-Object { $_.issue -eq 2 }).cli  | Should -Be 'claude'
    }
    It 'defaults to a claude-only fleet when no CLIs are given' {
        $plan = New-AssignmentPlan @( (New-Iss 1) ) @()
        $plan[0].cli | Should -Be 'claude'
    }
    It 'produces one plan entry per issue' {
        (New-AssignmentPlan @( (New-Iss 1), (New-Iss 2), (New-Iss 3) ) @('claude')).Count | Should -Be 3
    }
}
