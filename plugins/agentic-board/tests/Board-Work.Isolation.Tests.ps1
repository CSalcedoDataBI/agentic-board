#Requires -Modules Pester
<#  Pester tests for the work-copy isolation decision of Board-Work.ps1 -Start -Branch (#670).

    `-Branch` is meant to isolate: a busy working copy gets its own worktree. The decision only
    counted a DIRTY tree or another issue-* branch as busy, so a CLEAN tree standing on a long-lived
    feature branch was switched in place and the feature branch was left with no checkout. These
    drive New-IssueWorkspace against a REAL git clone (a bare origin reached over file:///), the
    same fixture style as the #294 wiring tests, and assert on what git ends up looking like. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    # Park the current clone on a new branch that holds one commit origin/main has never seen.
    function Add-FeatureCommit([string]$Name = 'feature-z') {
        git checkout -q -b $Name
        'unmerged work' | Set-Content (Join-Path $script:Clone "$Name.txt")
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m "work on $Name"
    }
}

Describe 'New-IssueWorkspace isolates a clean feature branch that carries work (#670)' {
    BeforeEach {
        # The remote must SPELL owner/name (New-IssueWorkspace refuses to branch otherwise), so the
        # bare origin lives at .../o/r and is reached over a file:/// URL - no network involved.
        $script:Repo   = 'o/r'
        $root          = Join-Path $TestDrive ('W' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $origin        = Join-Path $root 'o\r'
        New-Item -ItemType Directory -Path $origin -Force | Out-Null
        git init -q --bare -b main $origin
        $url = 'file:///' + ($origin -replace '\\', '/')

        $seed = Join-Path $root 'seed'
        git clone -q $url $seed 2>&1 | Out-Null
        'base' | Set-Content (Join-Path $seed 'a.txt')
        git -C $seed add -A 2>&1 | Out-Null
        git -C $seed -c user.email=t@t -c user.name=t commit -q -m base
        git -C $seed push -q origin main 2>&1 | Out-Null

        $script:Clone = Join-Path $root 'clone'
        git clone -q $url $script:Clone 2>&1 | Out-Null
        Push-Location $script:Clone
        git config user.email t@t
        git config user.name t
    }
    AfterEach { Pop-Location }

    It 'a CLEAN tree on a feature branch with unmerged commits gets a worktree and keeps its checkout' {
        Add-FeatureCommit
        (git status --porcelain) | Should -BeNullOrEmpty          # the fixture really is clean
        $wp = New-IssueWorkspace -repo $script:Repo -issueNum 70 -branchName 'issue-70-fix'
        $wp | Should -Not -BeNullOrEmpty
        $wp | Should -Not -Be $script:Clone
        (Test-Path $wp) | Should -BeTrue
        (git -C $script:Clone branch --show-current) | Should -Be 'feature-z'   # NOT stranded
        (git -C $wp branch --show-current)           | Should -Be 'issue-70-fix'
        (Test-Path (Join-Path $wp 'feature-z.txt'))  | Should -BeFalse          # base is origin/main
    }

    It 'says why: the current branch and how many commits it carries' {
        Add-FeatureCommit
        $out = New-IssueWorkspace -repo $script:Repo -issueNum 71 -branchName 'issue-71-fix' 6>&1 | Out-String
        $out | Should -Match 'feature-z'
        $out | Should -Match '1 commit'
    }

    It 'a clean tree on main goes in place, as before (no false positive)' {
        $wp = New-IssueWorkspace -repo $script:Repo -issueNum 72 -branchName 'issue-72-fix'
        $wp | Should -Be $script:Clone
        (git branch --show-current) | Should -Be 'issue-72-fix'
    }

    It 'a clean tree on a feature branch whose commits are already in origin/main goes in place' {
        # Push the feature to main from another clone so the local branch has nothing unmerged.
        Add-FeatureCommit
        git push -q origin feature-z:main 2>&1 | Out-Null
        git fetch -q origin 2>&1 | Out-Null
        (git rev-list --count origin/main..HEAD) | Should -Be '0'
        $wp = New-IssueWorkspace -repo $script:Repo -issueNum 73 -branchName 'issue-73-fix'
        $wp | Should -Be $script:Clone
    }

    It 'standing on the issue branch itself is not "busy" (re-running -Start resumes in place)' {
        $null = New-IssueWorkspace -repo $script:Repo -issueNum 74 -branchName 'issue-74-fix'
        'more' | Set-Content (Join-Path $script:Clone 'more.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m 'progress on the issue'
        $wp = New-IssueWorkspace -repo $script:Repo -issueNum 74 -branchName 'issue-74-fix'
        $wp | Should -Be $script:Clone
    }

    It '-BaseCurrent is the explicit opt-in to continue from the current branch: no base to compare, unchanged' {
        Add-FeatureCommit
        $wp = New-IssueWorkspace -repo $script:Repo -issueNum 75 -branchName 'issue-75-dep' -BaseCurrent
        $wp | Should -Be $script:Clone
        (Test-Path (Join-Path $script:Clone 'feature-z.txt')) | Should -BeTrue
    }
}

Describe 'the session briefing tells the agent to commit with an explicit pathspec (#547)' {
    It 'says so, in both the normal and the braked (-StopAtPR) briefing' {
        foreach ($b in @((Get-SessionBriefing 42 'o/r' 'issue-42-x' 'C:\wt'), (Get-SessionBriefing 42 'o/r' 'issue-42-x' 'C:\wt' -StopAtPR))) {
            $b | Should -Match 'EXPLICIT PATHSPEC'
            $b | Should -Match 'git commit -m <message> -- <paths>'
            $b | Should -Match 'never a bare'
        }
    }
    It 'the shared skill reference documents the same rule where step 5 commits' {
        $ref = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'skills' 'projects-admin' 'references' 'verbs-work.md') -Raw
        ($ref -match 'explicit\s+pathspec') | Should -BeTrue
    }
}

Describe 'Get-UnintegratedCommitCount' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ('C' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Push-Location $script:Dir
        git init -q -b main
        git config user.email t@t
        git config user.name t
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
        git branch base
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m three
    }
    AfterEach { Pop-Location }

    It 'counts the commits HEAD has that the base lacks' {
        Get-UnintegratedCommitCount 'base' | Should -Be 2
        Get-UnintegratedCommitCount 'main' | Should -Be 0
    }
    It 'answers -1 (unknown), never 0, when there is no base or git cannot resolve it' {
        Get-UnintegratedCommitCount ''                   | Should -Be -1
        Get-UnintegratedCommitCount 'origin/no-such-ref' | Should -Be -1
    }
}
