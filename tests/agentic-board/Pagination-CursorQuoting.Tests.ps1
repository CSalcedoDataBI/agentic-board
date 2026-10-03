#Requires -Modules Pester
<#  Source-level regression lock for #329 across ALL paginated board reads.

    Every Projects-v2 read that paginates once built its page-2 cursor argument by splicing it
    into the query text as  after: "$cursor"  — embedded double-quotes and all. PowerShell does
    not escape embedded double-quotes in a native gh.exe argument, so gh received the base64
    cursor UNQUOTED and its `==` padding parsed as bare GraphQL tokens ("Expected NAME, actual
    EQUALS"). Latent until the board crossed 100 items and a second page (hence a cursor) existed;
    then it broke -Start / -ToReview / -Parallel / -Fleet, the changelog, the gap-filler and the
    fleet planner all at once.

    The fix is uniform: declare `$cursor:String`, reference `after:$cursor`, and pass the value as
    a GraphQL variable via `-f cursor=<value>`. Three of the four sites are exercised behaviourally
    at the Invoke-GhRaw seam (Board-Work Get-BoardItem, Board-Fill Get-BoardItems, Fleet-Plan
    Get-PendingBoardIssues). The fourth — Board-Changelog's top-level read loop — is not function-
    extracted, so this source scan is its regression coverage, and a uniform backstop for the rest.

    Full-line `#` comments are stripped before matching: the notes above and beside each fix
    deliberately name the anti-pattern to warn future editors, and must not trip their own guard. #>

Describe 'Paginated board reads thread the cursor as a GraphQL variable, never quoted into the query (#329)' {
    # -ForEach is evaluated at Discovery, so the file list is an inline literal (a $script: var set
    # in BeforeAll would still be $null here).
    $paginated = 'Board-Work.ps1', 'Board-Changelog.ps1', 'Board-Fill.ps1', 'Fleet-Plan.ps1'

    BeforeAll {
        function Get-CodeOnly([string]$fileName) {
            $path = Join-Path $PSScriptRoot '..' 'scripts' $fileName | Resolve-Path
            # Drop whole-line comments so we assert on CODE, not the explanatory prose.
            (Get-Content $path) | Where-Object { $_ -notmatch '^\s*#' } | Out-String
        }
    }

    It '<_> never splices the cursor into the query as an after:"..." clause' -ForEach $paginated {
        $code = Get-CodeOnly $_
        # The exact #329 hazard: a double-quote immediately after the `after:` GraphQL argument.
        $code | Should -Not -Match 'after:\s*"'
    }

    It '<_> threads the pagination cursor as a -f variable value' -ForEach $paginated {
        $code = Get-CodeOnly $_
        $code | Should -Match 'cursor=\$cursor'
    }
}
