#Requires -Modules Pester
<#  Tests for the HEAD-vs-registered-branch check of New-BoardPR.ps1 (#547).

    Two sessions sharing one working copy can leave a commit on the wrong branch, and nothing said
    so until the PR. The session that started the issue registered its branch in sessions.json;
    New-BoardPR now refuses to push a DIFFERENT branch for that issue from that working copy.

    The end-to-end cases run the real script through `pwsh -File` in a throw-away git repo. They
    pass a -TokenVar that does not exist, so a run that gets PAST the branch check stops on the
    identity step ("no esta en el entorno USER") - proof that the check let it through - without
    ever touching GitHub. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'New-BoardPR.ps1' | Resolve-Path
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = '1'
    . $script:Script -Issue 1
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = ''

    # A PID that certainly is not running, for the "dead session" case.
    $script:DeadPid = 900000
    while (Get-Process -Id $script:DeadPid -ErrorAction SilentlyContinue) { $script:DeadPid++ }

    function New-Entry([int]$Issue, [string]$Branch, [string]$WorkPath, [string]$Repo = 'o/r') {
        [pscustomobject]@{ issue = $Issue; repo = $Repo; branch = $Branch; workPath = $WorkPath; sessionPid = $PID }
    }
}

Describe 'Get-RegisteredBranchMismatch (pure)' {
    It 'is silent when the branch being pushed is the registered one' {
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'issue-5-x' | Should -Be ''
    }
    It 'refuses a different branch for the same issue in the same working copy, naming both' {
        $m = Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'feature/other'
        $m | Should -Match 'issue-5-x'
        $m | Should -Match 'feature/other'
        $m | Should -Match 'AllowBranchMismatch'
    }
    It 'compares the working copy across slash style, trailing separator and case' {
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\Repo\WT\') -Repo 'o/r' -Issues @(5) -WorkPath 'c:/repo/wt' -Branch 'other' | Should -Match 'issue-5-x'
    }
    It 'ignores an entry for another working copy (the same issue in a worktree elsewhere)' {
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\elsewhere') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'other' | Should -Be ''
    }
    It 'ignores an entry for another issue and one for another repo' {
        Get-RegisteredBranchMismatch -Entries @(New-Entry 6 'issue-6-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'other' | Should -Be ''
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\wt' 'x/y') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'other' | Should -Be ''
    }
    It 'checks every issue of a batch PR' {
        Get-RegisteredBranchMismatch -Entries @(New-Entry 7 'issue-7-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5, 7) -WorkPath 'C:/r/wt' -Branch 'other' | Should -Match 'issue-7-x'
    }
    It 'has nothing to say with no entries, no working copy or no branch' {
        Get-RegisteredBranchMismatch -Entries @() -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch 'b' | Should -Be ''
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5) -WorkPath '' -Branch 'b' | Should -Be ''
        Get-RegisteredBranchMismatch -Entries @(New-Entry 5 'issue-5-x' 'C:\r\wt') -Repo 'o/r' -Issues @(5) -WorkPath 'C:/r/wt' -Branch '' | Should -Be ''
    }
}

Describe 'Get-LiveSessionEntries' {
    It 'keeps a live PID and drops a dead one (a dead session must never count as holding the folder)' {
        $p = Join-Path $TestDrive 'sessions.json'
        @(
            [pscustomobject]@{ issue = 1; branch = 'a'; workPath = 'x'; sessionPid = $PID },
            [pscustomobject]@{ issue = 2; branch = 'b'; workPath = 'x'; sessionPid = $script:DeadPid }
        ) | ConvertTo-Json -AsArray | Set-Content $p
        $live = @(Get-LiveSessionEntries $p)
        $live.Count | Should -Be 1
        $live[0].issue | Should -Be 1
    }
    It 'returns nothing for a missing, empty or corrupt registry' {
        @(Get-LiveSessionEntries (Join-Path $TestDrive 'nope.json')).Count | Should -Be 0
        $e = Join-Path $TestDrive 'empty.json'; '' | Set-Content $e
        @(Get-LiveSessionEntries $e).Count | Should -Be 0
        $c = Join-Path $TestDrive 'corrupt.json'; '{not json' | Set-Content $c
        @(Get-LiveSessionEntries $c).Count | Should -Be 0
    }
}

Describe 'New-BoardPR.ps1 end to end: the registered-branch check (#547)' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        Push-Location $script:Repo
        git init -q -b main
        git config user.email t@t
        git config user.name t
        git commit -q --allow-empty -m base
        git checkout -q -b issue-5-x
        git branch other-branch
        Pop-Location

        # Run the real script from the temp repo. A nonexistent -TokenVar makes a run that clears the
        # branch check stop at the identity step, before any network call.
        function Invoke-Pr([string[]]$More = @()) {
            Push-Location $script:Repo
            try {
                $out = & pwsh -NoProfile -File $script:Script -Issue 5 -Repo 'o/r' -TokenVar 'ABIOS_TEST_NO_SUCH_VAR' @More 2>&1 | Out-String
                [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
            } finally { Pop-Location }
        }
        function Set-Registry([object[]]$Entries) {
            $dir = Join-Path $script:Repo '.agentic-board'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $Entries | ConvertTo-Json -AsArray | Set-Content (Join-Path $dir 'sessions.json')
        }
        function Set-Head([string]$Branch) { git -C $script:Repo checkout -q $Branch }
    }

    It 'lets the run through when HEAD is the registered branch' {
        Set-Head 'issue-5-x'
        Set-Registry @(New-Entry 5 'issue-5-x' $script:Repo)
        $r = Invoke-Pr
        $r.Out | Should -Not -Match 'se registro en la rama'
        $r.Out | Should -Match 'no esta en el entorno USER'     # it reached the identity step
    }
    It 'REFUSES when another session switched the folder to a different branch' {
        Set-Head 'other-branch'
        Set-Registry @(New-Entry 5 'issue-5-x' $script:Repo)
        $r = Invoke-Pr
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'se registro en la rama ''issue-5-x'''
        $r.Out  | Should -Match 'other-branch'
        $r.Out  | Should -Not -Match 'no esta en el entorno USER'   # stopped BEFORE the identity work
    }
    It '-AllowBranchMismatch warns and goes on' {
        Set-Head 'other-branch'
        Set-Registry @(New-Entry 5 'issue-5-x' $script:Repo)
        $r = Invoke-Pr @('-AllowBranchMismatch')
        $r.Out | Should -Match 'AVISO'
        $r.Out | Should -Match 'no esta en el entorno USER'
    }
    It 'an explicit -Branch equal to the registered one is fine even with HEAD elsewhere' {
        Set-Head 'other-branch'
        Set-Registry @(New-Entry 5 'issue-5-x' $script:Repo)
        $r = Invoke-Pr @('-Branch', 'issue-5-x')
        $r.Out | Should -Not -Match 'se registro en la rama'
        $r.Out | Should -Match 'no esta en el entorno USER'
    }
    It 'an explicit -Branch that is NOT the registered one is refused too' {
        Set-Head 'issue-5-x'
        Set-Registry @(New-Entry 5 'issue-5-x' $script:Repo)
        $r = Invoke-Pr @('-Branch', 'other-branch')
        $r.Code | Should -Be 1
        $r.Out  | Should -Match 'se registro en la rama'
    }
    It 'a DEAD session''s stale entry never blocks' {
        Set-Head 'other-branch'
        $stale = New-Entry 5 'issue-5-x' $script:Repo
        $stale.sessionPid = $script:DeadPid
        Set-Registry @($stale)
        $r = Invoke-Pr
        $r.Out | Should -Not -Match 'se registro en la rama'
        $r.Out | Should -Match 'no esta en el entorno USER'
    }
    It 'no registry at all changes nothing' {
        Set-Head 'other-branch'
        Remove-Item (Join-Path $script:Repo '.agentic-board') -Recurse -Force -ErrorAction SilentlyContinue
        $r = Invoke-Pr
        $r.Out | Should -Match 'no esta en el entorno USER'
    }
}
