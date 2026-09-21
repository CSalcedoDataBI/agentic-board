#Requires -Modules Pester
<#  Tests for cross-repo issues in the fleet (#487).

    The fleet assumed 1 issue = 1 repo = 1 worktree = 1 PR. These pin the safe minimum the issue
    asks for: the case is DETECTED (label or a target-repos list), the session briefing stops
    telling the agent to implement in the worktree and to open a `Closes #n` PR in another repo, and
    the session registry records the PRs a session really has live. The registry tests run against a
    REAL sessions.json in a throwaway git repo; only gh is faked. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    function New-Throwaway {
        param([string]$Name)
        $p = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Push-Location $p; git init -q -b main 2>&1 | Out-Null; Pop-Location
        $p
    }
}

Describe 'Get-IssueTargetRepos' {
    It 'reads a list under a "Target repos:" header, excluding the issue''s own repo' {
        $body = "Put our link in the READMEs.`r`n`r`nTarget repos:`r`n- o/a`r`n- ``o/b```r`n- home/site`r`n`r`nMore text."
        $r = Get-IssueTargetRepos -Body $body -HomeRepo 'home/site'
        $r.CrossRepo | Should -BeTrue
        $r.Repos     | Should -Be @('o/a', 'o/b')
    }
    It 'accepts a markdown heading, urls, numbered items and the Spanish header' {
        $body = "## Repos objetivo`n1. https://github.com/o/a`n2) o/b.git`n"
        (Get-IssueTargetRepos -Body $body -HomeRepo 'x/y').Repos | Should -Be @('o/a', 'o/b')
    }
    It 'accepts the slugs inline after the header' {
        (Get-IssueTargetRepos -Body 'Target repos: o/a, o/b' -HomeRepo 'x/y').Repos | Should -Be @('o/a', 'o/b')
    }
    It 'de-duplicates case-insensitively and keeps order' {
        (Get-IssueTargetRepos -Body "Target repos:`n- O/A`n- o/b`n- o/a" -HomeRepo 'x/y').Repos | Should -Be @('O/A', 'o/b')
    }
    It 'treats the cross-repo label alone as cross-repo with no named targets' {
        $r = Get-IssueTargetRepos -Body 'no list here' -Labels @('bug', 'Cross-Repo') -HomeRepo 'x/y'
        $r.CrossRepo | Should -BeTrue
        @($r.Repos).Count | Should -Be 0
    }
    It 'is NOT cross-repo when the list only names the issue''s own repo' {
        $r = Get-IssueTargetRepos -Body "Target repos:`n- x/y" -HomeRepo 'X/Y'
        $r.CrossRepo | Should -BeFalse
    }
    It 'is NOT cross-repo for an ordinary issue, and never invents targets from prose' {
        $r = Get-IssueTargetRepos -Body 'We should touch owner/name and also other/repo somewhere.' -Labels @('feature') -HomeRepo 'x/y'
        $r.CrossRepo | Should -BeFalse
        @($r.Repos).Count | Should -Be 0
    }
    It 'does not take slashed words out of an inline sentence for repositories' {
        $r = Get-IssueTargetRepos -Body 'Target repos: update the a/b module and configure TCP/IP' -HomeRepo 'x/y'
        $r.CrossRepo | Should -BeFalse
        @($r.Repos).Count | Should -Be 0
    }
    It 'stops the list at a line that is not a repo (no swallowing the rest of the issue)' {
        $body = "Target repos:`n- o/a`n- not a repo at all`n- o/c`n"
        (Get-IssueTargetRepos -Body $body -HomeRepo 'x/y').Repos | Should -Be @('o/a')
    }
    It 'survives an empty or missing body' {
        (Get-IssueTargetRepos -Body '' -HomeRepo 'x/y').CrossRepo | Should -BeFalse
        (Get-IssueTargetRepos -HomeRepo 'x/y').CrossRepo | Should -BeFalse
    }
}

Describe 'Get-PullRequestRef / Merge-SessionPullRequest' {
    It 'parses owner/name#n and a PR url, and rejects anything else' {
        (Get-PullRequestRef 'o/a#12').Repo   | Should -Be 'o/a'
        (Get-PullRequestRef 'o/a#12').Number | Should -Be 12
        (Get-PullRequestRef 'https://github.com/o/a/pull/7').Number | Should -Be 7
        Get-PullRequestRef '12'        | Should -BeNullOrEmpty
        Get-PullRequestRef 'o/a#'      | Should -BeNullOrEmpty
        Get-PullRequestRef 'o/a#12x'   | Should -BeNullOrEmpty
    }
    It 'adds a PR once, however many times it is recorded' {
        $l = Merge-SessionPullRequest -Existing @() -Repo 'o/a' -Number 1
        $l = Merge-SessionPullRequest -Existing $l -Repo 'O/A' -Number 1
        $l = Merge-SessionPullRequest -Existing $l -Repo 'o/b' -Number 1
        @($l).Count | Should -Be 2
    }
}

Describe 'the session registry records cross-repo facts and PRs (real sessions.json)' {
    BeforeAll { $script:Repo1 = New-Throwaway 'reg' }

    It 'stores targetRepos, crossRepo and an empty prs list when the session is registered' {
        Push-Location $script:Repo1
        try {
            Write-SessionRegistryEntry -IssueNum 271 -Branch 'issue-271-x' -WorkPath 'C:/w' -Repo 'home/site' -SessionPid 4242 -Via 'pwsh' `
                                       -TargetRepos @('o/a', 'o/b') -CrossRepo $true
            $row = @(Read-SessionRegistryRaw)[0]
        } finally { Pop-Location }
        $row.crossRepo | Should -BeTrue
        @($row.targetRepos) | Should -Be @('o/a', 'o/b')
        @($row.prs).Count | Should -Be 0
    }
    It 'records PRs from other repos against the session, without duplicates' {
        Push-Location $script:Repo1
        try {
            (Add-SessionPullRequest -IssueNum 271 -Repo 'o/a' -Number 5).Ok | Should -BeTrue
            (Add-SessionPullRequest -IssueNum 271 -Repo 'o/b' -Number 9).Ok | Should -BeTrue
            (Add-SessionPullRequest -IssueNum 271 -Repo 'o/a' -Number 5).Ok | Should -BeTrue
            $row = @(Read-SessionRegistryRaw)[0]
        } finally { Pop-Location }
        @($row.prs).Count | Should -Be 2
        (@($row.prs) | ForEach-Object { "$($_.repo)#$($_.number)" }) | Should -Be @('o/a#5', 'o/b#9')
    }
    It 'a later PID/via-only update (a relaunch) keeps the targets and the recorded PRs' {
        Push-Location $script:Repo1
        try {
            Write-SessionRegistryEntry -IssueNum 271 -SessionPid 9999 -Via 'pwsh'
            $row = @(Read-SessionRegistryRaw)[0]
        } finally { Pop-Location }
        $row.sessionPid | Should -Be 9999
        @($row.targetRepos) | Should -Be @('o/a', 'o/b')
        $row.crossRepo | Should -BeTrue
        @($row.prs).Count | Should -Be 2
    }
    It 'refuses to record a PR for an issue with no session, and does not invent a row' {
        Push-Location $script:Repo1
        try {
            $r = Add-SessionPullRequest -IssueNum 999 -Repo 'o/a' -Number 1
            $rows = @(Read-SessionRegistryRaw)
        } finally { Pop-Location }
        $r.Ok | Should -BeFalse
        $rows.Count | Should -Be 1
    }
    It 'refuses when sessions.json is unreadable and leaves it untouched' {
        $r2 = New-Throwaway 'reg-corrupt'
        Push-Location $r2
        try {
            $p = Get-SessionRegistryPath
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            Set-Content -LiteralPath $p -Value '{ nope'
            $r = Add-SessionPullRequest -IssueNum 1 -Repo 'o/a' -Number 1
            $after = Get-Content -LiteralPath $p -Raw
        } finally { Pop-Location }
        $r.Ok | Should -BeFalse
        $after.Trim() | Should -Be '{ nope'
    }
    It 'a single-repo session is unaffected: no targets, not cross-repo, no PRs' {
        $r3 = New-Throwaway 'reg-plain'
        Push-Location $r3
        try {
            Write-SessionRegistryEntry -IssueNum 5 -Branch 'issue-5-x' -WorkPath 'C:/w' -Repo 'o/r' -SessionPid 1234 -Via 'pwsh'
            $row = @(Read-SessionRegistryRaw)[0]
        } finally { Pop-Location }
        $row.crossRepo | Should -BeFalse
        @($row.targetRepos).Count | Should -Be 0
    }
    It '-RecordPr on the real script writes the row and rejects a malformed reference' {
        $r4 = New-Throwaway 'reg-cli'
        Push-Location $r4
        try {
            Write-SessionRegistryEntry -IssueNum 8 -Branch 'issue-8-x' -WorkPath 'C:/w' -Repo 'o/r' -SessionPid 1234 -Via 'pwsh'
            $env:GH_TOKEN = ''
            $ok  = pwsh -NoProfile -File $script:Script -RecordPr 'o/a#3' -ForIssue 8 -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
            $bad = pwsh -NoProfile -File $script:Script -RecordPr 'garbage' -ForIssue 8 -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
            $noIssue = pwsh -NoProfile -File $script:Script -RecordPr 'o/a#3' -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
            $row = @(Read-SessionRegistryRaw)[0]
        } finally { Pop-Location }
        $ok | Should -Match 'anotado'
        $bad | Should -Match 'owner/name#numero'
        $noIssue | Should -Match '-ForIssue'
        @($row.prs).Count | Should -Be 1
    }
}

Describe 'Invoke-IssueStart detects a cross-repo issue and records it' {
    BeforeAll {
        $script:Ctx = [pscustomobject]@{ projectId = 'P'; statusNode = [pscustomobject]@{ id = 'F' }; inProgId = 'O' }
        function New-XItem {
            param([string]$Body = '', [string[]]$Labels = @())
            [pscustomobject]@{
                id = 'ITEM'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content = [pscustomobject]@{
                    __typename = 'Issue'; number = 271; title = 'SEO links'; state = 'OPEN'; url = 'u'; body = $Body
                    labels = [pscustomobject]@{ nodes = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                    assignees = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'home/site' }
                }
            }
        }
    }
    It 'reports the target repos on the dry-run result' {
        Mock Get-BoardItem { New-XItem -Body "Target repos:`n- o/a`n- o/b`n" }
        Mock Get-IssueBlockers { @() }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @(); revertedAt = $null } }
        $r = Invoke-IssueStart -IssueNum 271 -Ctx $script:Ctx -Owner 'me' -DryRunStart
        $r.crossRepo | Should -BeTrue
        $r.targetRepos | Should -Be @('o/a', 'o/b')
    }
    It 'leaves an ordinary issue single-repo' {
        Mock Get-BoardItem { New-XItem -Body 'just do it' }
        Mock Get-IssueBlockers { @() }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @(); revertedAt = $null } }
        $r = Invoke-IssueStart -IssueNum 271 -Ctx $script:Ctx -Owner 'me' -DryRunStart
        $r.crossRepo | Should -BeFalse
        @($r.targetRepos).Count | Should -Be 0
    }
    It 'writes the cross-repo facts into the session registry row of a real start' {
        $r5 = New-Throwaway 'start'
        Mock Get-BoardItem { New-XItem -Labels @('cross-repo') -Body "Target repos: o/a" }
        Mock Get-IssueBlockers { @() }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @(); revertedAt = $null } }
        Mock Invoke-Gh { $null }
        Mock New-IssueWorkspace { 'C:/work/issue-271' }
        Push-Location $r5
        try {
            $r = Invoke-IssueStart -IssueNum 271 -Ctx $script:Ctx -Owner 'me' -MakeBranch
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 271 })[0]
        } finally { Pop-Location }
        $r.started | Should -BeTrue
        $row.crossRepo | Should -BeTrue
        @($row.targetRepos) | Should -Be @('o/a')
    }
}

Describe 'Get-SessionBriefing for a cross-repo issue' {
    BeforeAll {
        $script:Work = Join-Path $TestDrive 'site--worktrees\issue-271'
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $script:Single = Get-SessionBriefing 271 'home/site' 'issue-271-x' $script:Work
        $script:Cross  = Get-SessionBriefing 271 'home/site' 'issue-271-x' $script:Work -TargetRepos @('o/a', 'o/b')
        $script:Braked = Get-SessionBriefing 271 'home/site' 'issue-271-x' $script:Work -TargetRepos @('o/a') -StopAtPR
        $script:LabelOnly = Get-SessionBriefing 271 'home/site' 'issue-271-x' $script:Work -CrossRepo
    }
    It 'leaves the single-repo briefing exactly as it was' {
        $script:Single | Should -Match 'implement it fully in this worktree'
        $script:Single | Should -Not -Match 'CROSS-REPO'
        $script:Single | Should -Not -Match '-RecordPr'
    }
    It 'tells the session the worktree is a base, names the target repos and asks for one PR per repo' {
        $script:Cross | Should -Match 'CROSS-REPO'
        $script:Cross | Should -Match 'o/a, o/b'
        $script:Cross | Should -Match 'NOT the destination'
        $script:Cross | Should -Match 'ONE PR per target repo'
        $script:Cross | Should -Not -Match 'implement it fully in this worktree'
    }
    It 'forbids Closes across repos and closing the issue by hand, and asks to record every PR' {
        $script:Cross | Should -Match "writes 'Refs home/site#271' instead of 'Closes'"
        $script:Cross | Should -Match '-IssueRepo home/site'
        $script:Cross | Should -Match '-RecordPr <target owner/name>#<pr number> -ForIssue 271'
        $script:Cross | Should -Match 'Do NOT close issue #271'
    }
    It 'names a Board-Work script that exists on disk' {
        $tok = [regex]::Match($script:Cross, 'pwsh ("[^"]+Board-Work\.ps1"|\S+Board-Work\.ps1) -RecordPr').Groups[1].Value.Trim('"')
        (Test-Path -LiteralPath $tok) | Should -BeTrue
    }
    It 'keeps the brake: a braked cross-repo briefing has no merge step, an unbraked one merges per PR' {
        $script:Braked | Should -Not -Match 'Board-Merge'
        $script:Braked | Should -Match 'STOP'
        $script:Cross  | Should -Match 'merge each PR'
    }
    It 'a label-only cross-repo issue is told to read the issue for the targets' {
        $script:LabelOnly | Should -Match 'the issue itself names'
    }
}

Describe 'the dashboard lines for recorded PRs' {
    It 'says how many are merged and that no single PR closes the issue' {
        $prs = @([pscustomobject]@{ repo = 'o/a'; number = 5 }, [pscustomobject]@{ repo = 'o/b'; number = 9 })
        $lines = @(Format-SessionPrLines -Prs $prs -States @{ 'o/a#5' = 'MERGED'; 'o/b#9' = 'OPEN' })
        $lines[0] | Should -Be 'PR o/a#5 [MERGED]'
        $lines[1] | Should -Be 'PR o/b#9 [OPEN]'
        $lines[2] | Should -Match '1 de 2 PR'
        $lines[2] | Should -Match 'cuando estan todos'
    }
    It 'prints an unreadable PR as unknown, never as merged' {
        $lines = @(Format-SessionPrLines -Prs @([pscustomobject]@{ repo = 'o/a'; number = 5 }) -States @{})
        $lines[0] | Should -Match 'desconocido'
        $lines[1] | Should -Match '0 de 1'
    }
    It 'prints nothing for a session with no recorded PRs' {
        @(Format-SessionPrLines -Prs @() -States @{}).Count | Should -Be 0
    }
}

Describe 'a launched session is briefed from the registry row written at start (Start-WorktreeSession)' {
    It 'a cross-repo row yields the cross-repo briefing file; a plain row yields the classic one' {
        $r6 = New-Throwaway 'launch'
        $work = Join-Path $TestDrive 'launch-work'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Mock Start-Process { $null }
        Push-Location $r6
        try {
            Write-SessionRegistryEntry -IssueNum 271 -Branch 'issue-271-x' -WorkPath $work -Repo 'home/site' -SessionPid 4242 -Via 'pwsh' -TargetRepos @('o/a') -CrossRepo $true
            Write-SessionRegistryEntry -IssueNum 272 -Branch 'issue-272-x' -WorkPath $work -Repo 'home/site' -SessionPid 4243 -Via 'pwsh'
            Start-WorktreeSession -IssueNum 271 -Repo 'home/site' -Branch 'issue-271-x' -WorkPath $work -StopAtPR | Out-Null
            # A session whose row has only the flag (label-only issue) must still get the cross-repo briefing.
            Write-SessionRegistryEntry -IssueNum 273 -Branch 'issue-273-x' -WorkPath $work -Repo 'home/site' -SessionPid 4244 -Via 'pwsh' -CrossRepo $true
            Start-WorktreeSession -IssueNum 273 -Repo 'home/site' -Branch 'issue-273-x' -WorkPath $work -StopAtPR | Out-Null
            Start-WorktreeSession -IssueNum 272 -Repo 'home/site' -Branch 'issue-272-x' -WorkPath $work -StopAtPR | Out-Null
            $dir = Get-AbiosStateDir
            $cross = Get-Content -LiteralPath (Join-Path $dir 'briefing-271.txt') -Raw
            $plain = Get-Content -LiteralPath (Join-Path $dir 'briefing-272.txt') -Raw
            $flagOnly = Get-Content -LiteralPath (Join-Path $dir 'briefing-273.txt') -Raw
        } finally { Pop-Location }
        $cross | Should -Match 'CROSS-REPO'
        $cross | Should -Match 'lands in these OTHER repositories: o/a\.'
        $flagOnly | Should -Match 'the issue itself names'
        $plain | Should -Not -Match 'CROSS-REPO'
        $plain | Should -Match 'implement it fully in this worktree'
    }
}