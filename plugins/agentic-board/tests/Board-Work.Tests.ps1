#Requires -Modules Pester
<#  Pester tests for Board-Work.ps1 - the /board work driver.

    Board-Work.ps1 is a side-effecting command (gh + Write-Host), so it exposes a
    dot-source guard: with $env:ABIOS_BOARDWORK_DOTSOURCE set, it returns after
    defining every function WITHOUT the token check or any gh call. That lets us
    unit-test the pure helpers, and - by mocking the three gh-touching helpers
    (Get-BoardItem, Get-IssueBlockers, Get-LastClaim) - the batch safety refusals
    and the dry-run plan of Invoke-IssueStart, all with zero network access. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    # A dummy board context - only consumed AFTER the dry-run/refusal early returns,
    # so it never has to be real for these tests.
    $script:Ctx = [pscustomobject]@{
        projectId  = 'PROJ'
        statusNode = [pscustomobject]@{ id = 'FIELD' }
        inProgId   = 'OPT'
    }

    # Build a fake board item shaped exactly like Get-BoardItem's GraphQL result.
    function New-FakeItem {
        param(
            [string]  $Title     = 'Do a thing',
            [string]  $Repo      = 'owner/repo',
            [string]  $State     = 'OPEN',
            [string]  $Status    = 'Backlog',
            [string[]]$Assignees = @()
        )
        [pscustomobject]@{
            id          = 'ITEM'
            fieldValues = [pscustomobject]@{ nodes = @(
                [pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = $Status }
            ) }
            content = [pscustomobject]@{
                __typename = 'Issue'; number = 1; title = $Title; state = $State; url = 'u'
                assignees  = [pscustomobject]@{ nodes = @($Assignees | ForEach-Object { [pscustomobject]@{ login = $_ } }) }
                repository = [pscustomobject]@{ nameWithOwner = $Repo }
            }
        }
    }
}

Describe 'Board-Work graphql reads fail closed (#314, part of #303)' {
    # Board-Work dot-sources Invoke-Gh BEFORE its guard, so the Invoke-GhRaw seam is defined here
    # too. Mocking it reproduces any exit code / body with no token and no network. These reads
    # DRIVE writes (Status moves) and board lookups; a silent failure is the #303/#314 class.

    Context 'Get-BoardItem (paginated board scan)' {
        It 'THROWS on a non-zero exit instead of silently truncating pagination (false "not on board")' {
            Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'HTTP 401: Bad credentials' } }
            { Get-BoardItem 'PVT_x' 5 } | Should -Throw
        }
        It 'THROWS on a graphql errors[] body despite exit 0' {
            Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"boom"}]}'; ExitCode = 0; StdErr = '' } }
            { Get-BoardItem 'PVT_x' 5 } | Should -Throw
        }
        It 'passes the page-2 cursor as a -f variable, never spliced into the query as after: "..." (#329)' {
            # A board >100 items needs a 2nd page. The cursor must ride as a GraphQL variable
            # (-f cursor=), NOT be interpolated into the query text as after: "$cursor": PowerShell
            # does not escape embedded double-quotes in a native gh.exe argument, so gh saw the
            # base64 cursor UNQUOTED and its `==` padding parsed as bare tokens -> the board-wide
            # "Expected NAME, actual EQUALS" that broke every read once the board crossed 100 items.
            # Page is chosen by CALL COUNT, not arg content, so a regression that still paginates
            # (via query interpolation) terminates and fails on the assertions instead of looping.
            $script:pgCalls = @(); $script:pgN = 0
            Mock Invoke-GhRaw {
                $script:pgCalls += ,@($GhArgs); $script:pgN++
                if ($script:pgN -ge 2) {
                    [pscustomobject]@{ Output = '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"I2","content":{"__typename":"Issue","number":5}}]}}}}'; ExitCode = 0; StdErr = '' }
                } else {
                    [pscustomobject]@{ Output = '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR=="},"nodes":[{"id":"I1","content":{"__typename":"Issue","number":99}}]}}}}'; ExitCode = 0; StdErr = '' }
                }
            }
            $item = Get-BoardItem 'PVT_x' 5
            $item.content.number  | Should -Be 5            # found on the 2nd page
            $script:pgCalls.Count | Should -Be 2            # both pages fetched
            (@($script:pgCalls[1]) -contains 'cursor=CUR==') | Should -BeTrue   # cursor as a -f value
            foreach ($c in $script:pgCalls) {
                $qArg = @($c) | Where-Object { $_ -like 'query=*' }
                $qArg | Should -Not -Match 'after:\s*"'     # the #329 anti-pattern (embedded quotes)
                $qArg | Should -Match 'after:\$cursor'      # cursor referenced as a variable
            }
        }
    }

    Context 'Resolve-BoardStatus (board id + Status field that every start writes against)' {
        It 'names the graphql failure, not a misleading "board not found", on an errors[] body' {
            # A null-id guard already throws here, so a bare Should -Throw would pass even
            # un-hardened (for the wrong reason). Assert the MESSAGE so only -Graphql satisfies it.
            Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":null,"errors":[{"message":"boom"}]}'; ExitCode = 0; StdErr = '' } }
            { Resolve-BoardStatus 'owner' 13 } | Should -Throw -ExpectedMessage '*resolver el board*'
        }
        It 'returns the context (id + In Progress option) on a successful read - empty is not failure' {
            Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"data":{"user":{"projectV2":{"id":"PID","fields":{"nodes":[{"id":"F","name":"Status","options":[{"id":"O","name":"In Progress"}]}]}}}}}'; ExitCode = 0; StdErr = '' } }
            $ctx = Resolve-BoardStatus 'owner' 13
            $ctx.projectId | Should -Be 'PID'
            $ctx.inProgId  | Should -Be 'O'
        }
    }
}

Describe 'Invoke-BatchIssueStart (a fail-closed throw must not abort the -Parallel batch, #314)' {
    # #314 made the Status move + board read throw on a gh failure. On the batch path that would
    # abort the whole foreach and skip the summary - so the batch wraps each start and converts a
    # throw into a recorded skip. Mocking Invoke-IssueStart keeps this off git and the network.
    It 'converts a throw into a skip result so the batch keeps going' {
        Mock Invoke-IssueStart { throw "No pude mover #7 a In Progress (gh exit 1)" }
        $r = Invoke-BatchIssueStart -IssueNum 7 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.issue   | Should -Be 7
        $r.skipped | Should -Match 'error al iniciar'
    }
    It 'passes a successful start straight through' {
        Mock Invoke-IssueStart { [pscustomobject]@{ issue = 5; started = $true; skipped = ''; workPath = 'wp' } }
        $r = Invoke-BatchIssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeTrue
        $r.skipped | Should -BeNullOrEmpty
    }
}

Describe 'Get-ParallelQueue (batch parsing)' {
    It 'de-duplicates while preserving the requested order' {
        (Get-ParallelQueue 5,5,7,5) | Should -Be @(5,7)
    }
    It 'keeps an already-unique list untouched and in order' {
        (Get-ParallelQueue 3,1,2) | Should -Be @(3,1,2)
    }
    It 'drops non-positive numbers' {
        (Get-ParallelQueue 0,-3,4,-1) | Should -Be @(4)
    }
    It 'returns an empty array when nothing is valid' {
        @(Get-ParallelQueue 0,-1).Count | Should -Be 0
    }
    It 'returns an empty array for an empty input' {
        @(Get-ParallelQueue @()).Count | Should -Be 0
    }
    It 'splits a single comma-joined string (the `pwsh -File` case: "129,130" not @(129,130))' {
        (Get-ParallelQueue '129,130') | Should -Be @(129,130)
    }
    It 'splits comma tokens and trims whitespace' {
        (Get-ParallelQueue '129, 130 ,131') | Should -Be @(129,130,131)
    }
    It 'drops non-numeric junk tokens' {
        (Get-ParallelQueue 'abc,12x,7') | Should -Be @(7)
    }
}

Describe 'Get-IssueSlugBranch (branch naming)' {
    It 'slugifies a plain title' {
        Get-IssueSlugBranch 12 'Fix the thing' | Should -Be 'issue-12-fix-the-thing'
    }
    It 'collapses punctuation and trims dashes' {
        Get-IssueSlugBranch 9 '-Parallel batch start (foo)!' | Should -Be 'issue-9-parallel-batch-start-foo'
    }
    It 'truncates a long slug to <=40 chars on a word boundary' {
        $b = Get-IssueSlugBranch 7 'this is a very long issue title that keeps on going well past the limit'
        $b | Should -BeLike 'issue-7-*'
        $slug = $b -replace '^issue-7-', ''
        $slug.Length | Should -BeLessOrEqual 40
        $slug | Should -Not -Match '-$'   # never end on a dangling dash
    }
}

Describe 'Get-IssueWorktreePath (grouped worktree layout)' {
    It 'groups worktrees under <repo>--worktrees/issue-<n> (not scattered siblings)' {
        Get-IssueWorktreePath 'owner/agentic-board' 129 'C:\Repos' |
            Should -Be 'C:\Repos\agentic-board--worktrees\issue-129'
    }
    It 'uses only the repo name, dropping the owner' {
        Get-IssueWorktreePath 'CSalcedoDataBI/my-repo' 7 'D:\work' |
            Should -Be 'D:\work\my-repo--worktrees\issue-7'
    }
    It 'places every issue in the SAME grouping folder' {
        $a = Get-IssueWorktreePath 'o/r' 1 'C:\p'
        $b = Get-IssueWorktreePath 'o/r' 2 'C:\p'
        (Split-Path $a -Parent) | Should -Be (Split-Path $b -Parent)
    }
}

Describe 'Resolve-IssueBaseRef (an issue branch starts from the remote default, #294)' {
    # Real git repos over a real file-URL "origin" - the resolution order it implements
    # (origin/HEAD -> gh -> convention) is entirely git state, so mocking git would
    # only assert that the mock was called.
    BeforeEach {
        $script:Origin = Join-Path $TestDrive ('o' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Clone  = "$($script:Origin)-clone"
        git init -q --bare -b main $script:Origin
        $seed = "$($script:Origin)-seed"
        git clone -q $script:Origin $seed 2>&1 | Out-Null
        Push-Location $seed
        'base' | Set-Content (Join-Path $seed 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base
        git push -q origin main 2>&1 | Out-Null
        Pop-Location
        git clone -q $script:Origin $script:Clone 2>&1 | Out-Null
        Push-Location $script:Clone
    }
    AfterEach { Pop-Location }

    It 'resolves the remote default branch from origin/HEAD' {
        Resolve-IssueBaseRef | Should -Be 'origin/main'
    }

    It 'resolves a default branch that is NOT called main' {
        # A repo on `master` (or `develop`) must not silently fall back to origin/main.
        Push-Location $script:Origin
        git symbolic-ref HEAD refs/heads/develop 2>&1 | Out-Null
        Pop-Location
        Push-Location $script:Clone
        git branch -q develop main 2>&1 | Out-Null
        git push -q origin develop 2>&1 | Out-Null
        git remote set-head origin -a 2>&1 | Out-Null
        Resolve-IssueBaseRef | Should -Be 'origin/develop'
        Pop-Location
    }

    It 'falls back to convention when origin/HEAD is absent' {
        # origin/HEAD is written at clone time and is routinely missing (fetch-built
        # clones, older gits). Deleting it must not lose the base.
        #
        # -NoFetch is load-bearing, not an optimisation: since git 2.47
        # remote.origin.followRemoteHEAD defaults to `create`, so the fetch inside
        # Resolve-IssueBaseRef RECREATES origin/HEAD and step 1 answers again. Without
        # this switch the test passes with the convention fallback deleted entirely.
        git symbolic-ref -d refs/remotes/origin/HEAD 2>&1 | Out-Null
        Resolve-IssueBaseRef -NoFetch | Should -Be 'origin/main'
    }

    It 'returns empty rather than an unresolvable ref when there is no origin at all' {
        # A local-only repo still has to start an issue - it just cannot promise a base.
        $solo = Join-Path $TestDrive ('s' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $solo | Out-Null
        Push-Location $solo
        git init -q -b main
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
        Resolve-IssueBaseRef | Should -BeNullOrEmpty
        Pop-Location
    }
}

Describe 'New-IssueWorkspace picks the base itself (the #294 wiring)' {
    # THE regression test. New-IssueWorktree already honoured a base ref before #294 -
    # the bug was that nobody passed it one. So a test that hands the base in passes
    # against the buggy code and proves nothing; this one calls the wiring exactly as
    # Invoke-IssueStart does, and goes red if the base resolution is removed.
    BeforeEach {
        # New-IssueWorkspace refuses to branch unless origin matches the issue's repo, so
        # the remote has to SPELL owner/name. A Windows path cannot (it separates with \),
        # hence a real bare repo at .../o/r reached over a file:/// URL: it contains the
        # literal "o/r", and fetch still works locally without touching the network.
        $script:Repo4   = 'o/r'
        $root           = Join-Path $TestDrive ('W' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Origin4 = Join-Path $root 'o\r'
        New-Item -ItemType Directory -Path $script:Origin4 -Force | Out-Null
        git init -q --bare -b main $script:Origin4
        $url = 'file:///' + ($script:Origin4 -replace '\\', '/')
        $script:Clone4 = Join-Path $root 'clone'

        $seed = Join-Path $root 'seed'
        git clone -q $url $seed 2>&1 | Out-Null
        Push-Location $seed
        'base' | Set-Content (Join-Path $seed 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base
        git push -q origin main 2>&1 | Out-Null
        Pop-Location

        git clone -q $url $script:Clone4 2>&1 | Out-Null
        Push-Location $script:Clone4
        git config user.email t@t
        git config user.name t
        # Clean tree, parked on a feature branch with a commit main has never seen.
        git checkout -q -b feature-z
        'contamination' | Set-Content (Join-Path $script:Clone4 'foreign.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m 'foreign work nobody reviewed'
    }
    AfterEach { Pop-Location }

    It 'the fixture really is a clone of the issue repo (else every test below passes vacuously)' {
        # Guard on the guard: if the origin check silently stopped matching, New-IssueWorkspace
        # would return '' and the contamination assertions would "pass" having branched nothing.
        (git remote get-url origin) | Should -Match 'o/r'
    }

    It 'does NOT inherit the current branch commits - via the worktree path (dirty tree)' {
        'uncommitted' | Set-Content (Join-Path $script:Clone4 'dirty.txt')   # forces the worktree path
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 60 -branchName 'issue-60-fix'
        $wp | Should -Not -BeNullOrEmpty
        (Test-Path (Join-Path $wp 'foreign.txt')) | Should -BeFalse
        Push-Location $wp
        (git rev-list --count origin/main..HEAD) | Should -Be '0'
        Pop-Location
    }

    It 'does NOT inherit the current branch commits - via the in-place path (clean tree)' {
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 61 -branchName 'issue-61-fix'
        $wp | Should -Be $script:Clone4
        (git branch --show-current) | Should -Be 'issue-61-fix'
        (Test-Path (Join-Path $script:Clone4 'foreign.txt')) | Should -BeFalse
    }

    It '-BaseCurrent opts back in to the current HEAD' {
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 62 -branchName 'issue-62-dep' -BaseCurrent
        (Test-Path (Join-Path $wp 'foreign.txt')) | Should -BeTrue
    }

    It '-Base pins an explicit ref' {
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 63 -branchName 'issue-63-dep' -Base 'feature-z'
        (Test-Path (Join-Path $wp 'foreign.txt')) | Should -BeTrue
    }

    It 'refuses to branch when the cwd is not a clone of the issue repo' {
        New-IssueWorkspace -repo 'someone/else' -issueNum 64 -branchName 'issue-64-x' | Should -Be ''
        (git branch --show-current) | Should -Be 'feature-z'   # nothing was touched
    }

    It 'returns ONLY the work path - no leaked git/branch output (Invoke-IssueStart reads $r.workPath)' {
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 65 -branchName 'issue-65-fix'
        @($wp).Count | Should -Be 1
    }

    It 'forces a worktree when another live session is registered at the same workPath (#225)' {
        # Plant a fake sessions.json in the repo state dir. The entry uses $PID (the Pester
        # runner itself) as sessionPid - it is a live process, and it differs from myPid
        # (parent of the script's own $PID), so the code classifies it as a foreign session.
        $stateDir = Get-AbiosStateDir
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        $fakeEntry = [pscustomobject]@{
            issue        = 99
            repo         = $script:Repo4
            branch       = 'issue-99-other'
            workPath     = $script:Clone4
            sessionPid   = $PID
            via          = ''
            cli          = 'claude'
            fleetSession = ''
            host         = $env:COMPUTERNAME
            started      = '2026-01-01 00:00'
        }
        @($fakeEntry) | ConvertTo-Json -Depth 4 -AsArray |
            Set-Content (Join-Path $stateDir 'sessions.json')
        # Clean tree on feature-z -> would normally go in-place (no dirty files, not an
        # issue-* branch). The live session entry must override that and force a worktree.
        $wp = New-IssueWorkspace -repo $script:Repo4 -issueNum 66 -branchName 'issue-66-collision'
        $wp | Should -Not -Be $script:Clone4   # must NOT have stayed in the main clone
        $wp | Should -Not -BeNullOrEmpty       # must have returned a valid worktree path
    }
}

Describe 'New-IssueWorktree honours a base ref it is given' {
    BeforeEach {
        $script:Origin2 = Join-Path $TestDrive ('O' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Clone2  = "$($script:Origin2)-clone"
        git init -q --bare -b main $script:Origin2
        $seed = "$($script:Origin2)-seed"
        git clone -q $script:Origin2 $seed 2>&1 | Out-Null
        Push-Location $seed
        'base' | Set-Content (Join-Path $seed 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base
        git push -q origin main 2>&1 | Out-Null
        Pop-Location
        git clone -q $script:Origin2 $script:Clone2 2>&1 | Out-Null
        Push-Location $script:Clone2
        # A local feature branch carrying a commit that main has never seen.
        git checkout -q -b feature-x
        'contamination' | Set-Content (Join-Path $script:Clone2 'foreign.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m 'foreign work nobody reviewed'
    }
    AfterEach { Pop-Location }

    # NOTE: this asserts New-IssueWorktree's OWN contract only. It honoured a base ref
    # before #294 too, so none of these would have caught the bug - the wiring that
    # chooses the base is tested in the New-IssueWorkspace block above.
    It 'cuts the branch from the given base, not from the current HEAD' {
        $wt = New-IssueWorktree 'o/r' 42 'issue-42-fix' 'origin/main'
        $wt | Should -Not -BeNullOrEmpty
        Push-Location $wt
        (Test-Path (Join-Path $wt 'foreign.txt')) | Should -BeFalse
        $ahead = git rev-list --count origin/main..HEAD
        $ahead | Should -Be '0'
        Pop-Location
    }

    It 'still honours an explicit base ref (dependent work is opt-in, not the default)' {
        $wt = New-IssueWorktree 'o/r' 43 'issue-43-dep' 'feature-x'
        Push-Location $wt
        (Test-Path (Join-Path $wt 'foreign.txt')) | Should -BeTrue
        Pop-Location
    }

    It 'falls back to HEAD when no base can be resolved, rather than failing the start' {
        $wt = New-IssueWorktree 'o/r' 44 'issue-44-nobase' ''
        $wt | Should -Not -BeNullOrEmpty
        (Test-Path (Join-Path $wt 'foreign.txt')) | Should -BeTrue
    }
}

Describe 'New-IssueBranchInPlace bases a NEW branch on the remote default (#294)' {
    # The half of #294 the report did not describe. A CLEAN working copy parked on a
    # feature branch is not dirty and does not match issue-*, so it never reaches the
    # worktree path - it lands here, where `checkout -b` had the identical defect.
    BeforeEach {
        $script:Origin3 = Join-Path $TestDrive ('i' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Clone3  = "$($script:Origin3)-clone"
        git init -q --bare -b main $script:Origin3
        $seed = "$($script:Origin3)-seed"
        git clone -q $script:Origin3 $seed 2>&1 | Out-Null
        Push-Location $seed
        'base' | Set-Content (Join-Path $seed 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base
        git push -q origin main 2>&1 | Out-Null
        Pop-Location
        git clone -q $script:Origin3 $script:Clone3 2>&1 | Out-Null
        Push-Location $script:Clone3
        # Clean tree, parked on a feature branch with an unmerged commit.
        git checkout -q -b feature-y
        'contamination' | Set-Content (Join-Path $script:Clone3 'foreign.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m 'foreign work nobody reviewed'
        git config user.email t@t
        git config user.name t
    }
    AfterEach { Pop-Location }

    It 'does NOT inherit the feature branch commits when given the remote default' {
        New-IssueBranchInPlace 'issue-50-fix' (Resolve-IssueBaseRef) | Should -Be 'origin/main'
        (git branch --show-current) | Should -Be 'issue-50-fix'
        (Test-Path (Join-Path $script:Clone3 'foreign.txt')) | Should -BeFalse
        (git rev-list --count origin/main..HEAD) | Should -Be '0'
    }

    It 'inherits the current HEAD when no base is given (the pre-fix behaviour, now opt-in)' {
        New-IssueBranchInPlace 'issue-51-dep' '' | Should -Be ''
        (Test-Path (Join-Path $script:Clone3 'foreign.txt')) | Should -BeTrue
    }

    It 'checks out an existing branch instead of recreating it off the base' {
        git branch issue-52-old main 2>&1 | Out-Null
        New-IssueBranchInPlace 'issue-52-old' 'origin/main' | Should -Be 'existing'
        (git branch --show-current) | Should -Be 'issue-52-old'
    }

    It 'falls back to HEAD - loudly - when the base ref does not resolve' {
        # Must not fail the start, but must not pretend it used the base either.
        New-IssueBranchInPlace 'issue-53-badbase' 'origin/does-not-exist' | Should -Be ''
        (git branch --show-current) | Should -Be 'issue-53-badbase'
    }
}

Describe 'Get-SessionBriefing' {
    BeforeAll { $script:Brief = Get-SessionBriefing 42 'owner/repo' 'issue-42-x' 'C:\wt\path' }
    It 'is a single line (safe to pass on a command line)' {
        $script:Brief | Should -Not -Match "`n"
    }
    It 'names the issue, repo, branch and worktree' {
        $script:Brief | Should -Match '#42'
        $script:Brief | Should -Match 'owner/repo'
        $script:Brief | Should -Match 'issue-42-x'
    }
    It 'points at the PR + review-gate finish' {
        $script:Brief | Should -Match 'New-BoardPR\.ps1 -Issue 42'
        $script:Brief | Should -Match 'review gate'
    }
    It 'tells the session it is autonomous (do not stop to ask)' {
        $script:Brief | Should -Match 'AUTONOMOUSLY'
    }
    It 'finishes the merge through the ruleset-safe Board-Merge.ps1' {
        $script:Brief | Should -Match 'Board-Merge\.ps1'
    }
    It 'wires the fleet blackboard: read prior findings and record on completion' {
        $script:Brief | Should -Match 'Fleet-Findings\.ps1 -List'
        $script:Brief | Should -Match 'Fleet-Findings\.ps1 -Add'
    }
    It 'wires file-ownership: claim before editing and release when done' {
        $script:Brief | Should -Match 'Fleet-Ownership\.ps1 -Claim'
        $script:Brief | Should -Match 'Fleet-Ownership\.ps1 -Release'
    }
    It 'wires the upstream hand-off context' {
        $script:Brief | Should -Match 'Fleet-Handoff\.ps1 -Context'
    }
}

Describe 'Get-SessionBriefing -StopAtPR (the irreversible brake, #440)' {
    BeforeAll { $script:Braked = Get-SessionBriefing 42 'owner/repo' 'issue-42-x' 'C:\wt\path' -StopAtPR }

    It 'never orders the merge' {
        # THE bug: the default briefing commands `Board-Merge.ps1`, so a session obeying its
        # brief merged to main (and, on a Git-integration host, deployed) while the expert
        # contract said STOP. With the brake on, the order must not be emitted at all.
        $script:Braked | Should -Not -Match 'Board-Merge\.ps1'
    }
    It 'does not make the merge the completion condition' {
        $script:Braked | Should -Not -Match 'When the PR is merged'
    }
    It 'says explicitly where to stop' {
        $script:Braked | Should -Match 'STOP'
        $script:Braked | Should -Match 'do NOT merge'
    }
    It 'still delivers everything up to a reviewed PR' {
        $script:Braked | Should -Match 'New-BoardPR\.ps1 -Issue 42'
        $script:Braked | Should -Match 'review gate'
        $script:Braked | Should -Match 'Fleet-Findings\.ps1 -Add'
        $script:Braked | Should -Match 'Fleet-Ownership\.ps1 -Release'
    }
    It 'keeps every step numbered once, with no gap where (5) merge used to be' {
        # Renumbering regression guard: dropping a step must not leave "(5)" missing or duped.
        foreach ($n in 1..5) { ([regex]::Matches($script:Braked, "\($n\)")).Count | Should -Be 1 }
        $script:Braked | Should -Not -Match '\(6\)'
    }
    It 'is still a single line' {
        $script:Braked | Should -Not -Match "`n"
    }
    It 'leaves the default briefing untouched when the brake is off' {
        (Get-SessionBriefing 42 'owner/repo' 'issue-42-x' 'C:\wt') | Should -Match 'Board-Merge\.ps1'
    }
}

Describe 'Get-SessionBriefing -BriefFile (the expert brief must reach the session, #440)' {
    It 'points the session at the brief and gives it precedence' {
        $b = Get-SessionBriefing 42 'o/r' 'issue-42-x' 'C:\wt' -BriefFile 'C:\s\expert-brief-42.md'
        $b | Should -Match 'expert-brief-42\.md'
        $b | Should -Match 'read it FIRST'
        $b | Should -Match 'overrides'
    }
    It 'says nothing about a brief when none is passed' {
        (Get-SessionBriefing 42 'o/r' 'issue-42-x' 'C:\wt') | Should -Not -Match 'expert-brief'
    }
    It 'composes with the brake' {
        $b = Get-SessionBriefing 42 'o/r' 'issue-42-x' 'C:\wt' -StopAtPR -BriefFile 'C:\s\expert-brief-42.md'
        $b | Should -Not -Match 'Board-Merge\.ps1'
        $b | Should -Match 'expert-brief-42\.md'
        $b | Should -Not -Match "`n"
    }
}

Describe 'Get-SessionBriefing adapter-aware' {
    It 'keeps the claude briefing unchanged' {
        (Get-SessionBriefing 5 'o/r' 'issue-5-x' 'C:\wt' -Cli 'claude') | Should -Match 'AUTONOMOUSLY'
        (Get-SessionBriefing 5 'o/r' 'issue-5-x' 'C:\wt' -Cli 'claude') | Should -Match 'issue #5'
    }
    It 'still references the same PR + review-gate steps for any repl CLI' {
        (Get-SessionBriefing 5 'o/r' 'issue-5-x' 'C:\wt' -Cli 'gemini') | Should -Match 'New-BoardPR.ps1'
    }
    It 'defaults to claude behavior when -Cli is omitted' {
        (Get-SessionBriefing 5 'o/r' 'issue-5-x' 'C:\wt') | Should -Match 'AUTONOMOUSLY'
    }
}

Describe 'Resolve-ClaudeAuthVar' {
    It 'honors an explicit -ClaudeAuthVar even when the OAuth token exists' {
        Resolve-ClaudeAuthVar $true 'ANTHROPIC_API_KEY' $true | Should -Be 'ANTHROPIC_API_KEY'
    }
    It 'auto-prefers the subscription OAuth token when not explicit and it is present' {
        Resolve-ClaudeAuthVar $false 'ANTHROPIC_API_KEY' $true | Should -Be 'CLAUDE_CODE_OAUTH_TOKEN'
    }
    It 'falls back to the default when not explicit and no OAuth token' {
        Resolve-ClaudeAuthVar $false 'ANTHROPIC_API_KEY' $false | Should -Be 'ANTHROPIC_API_KEY'
    }
}

Describe 'Build-WorktreeLaunch' {
    It 'builds a Windows Terminal tab command when wt is present' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launcher | Should -Be 'wt'
        $p.usesWt   | Should -BeTrue
        $p.args     | Should -Contain 'new-tab'
        $p.args     | Should -Contain '--startingDirectory'
        $p.args     | Should -Contain 'C:\wt'
    }
    It 'launches via a -File script, never an inline -Command (so wt cannot split the tab)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.args | Should -Contain '-File'
        $p.args | Should -Not -Contain '-Command'
        $p.args | Should -Contain $p.launchScriptFile
    }
    It 'REGRESSION: puts no semicolon on the wt command line (a ; there splits one tab into many)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        ($p.args -join ' ') | Should -Not -Match ';'
    }
    It 'names the launch script per issue, alongside the briefing' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\abios\brief.txt' 'C:\brief.txt'
        # launchScriptFile sits in the briefing's directory, keyed by issue number
        $p.launchScriptFile | Should -Match 'launch-12\.ps1$'
    }
    It 'falls back to a pwsh window when wt is absent' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launcher | Should -Be 'pwsh'
        $p.usesWt   | Should -BeFalse
        $p.args     | Should -Contain '-NoExit'
        $p.args     | Should -Contain '-File'
    }
    It 'passes the briefing by file, never inline' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launchScript | Should -Match 'brief\.txt'
    }
    It 'runs the spawned session unattended headless (no interactive prompt can stall it)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launchScript | Should -Match 'claude -p '                          # headless: skips trust + bypass-accept prompts
        $p.launchScript | Should -Match '--permission-mode bypassPermissions' # no per-tool approval stalls
        $p.launchScript | Should -Match '--no-session-persistence'            # parallel sessions don't collide
    }
    It 'injects the child auth credential by env-var NAME (secret never on the command line)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'MY_AUTH_VAR'
        # same-name injection: $env:MY_AUTH_VAR = [Environment]::GetEnvironmentVariable('MY_AUTH_VAR','User')
        $p.launchScript | Should -Match '\$env:MY_AUTH_VAR='                       # sets the child's credential
        $p.launchScript | Should -Match "GetEnvironmentVariable\('MY_AUTH_VAR','User'"  # read at runtime, by NAME, from registry
        $p.launchScript | Should -Match 'Remove-Item Env:CLAUDECODE'              # drop inherited host session markers
    }
    It 'defaults the auth credential to ANTHROPIC_API_KEY' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launchScript | Should -Match '\$env:ANTHROPIC_API_KEY='
    }
    It 'clears competing Anthropic credentials so the chosen one is authoritative' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        # with CLAUDE_CODE_OAUTH_TOKEN chosen, the inherited ANTHROPIC_API_KEY must be cleared
        # first (it outranks the OAuth token in auth precedence) or it would win silently.
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'CLAUDE_CODE_OAUTH_TOKEN'
        $s = $p.launchScript
        $s | Should -Match 'Remove-Item Env:ANTHROPIC_API_KEY,Env:ANTHROPIC_AUTH_TOKEN,Env:CLAUDE_CODE_OAUTH_TOKEN'
        # ...and the clear happens BEFORE the chosen credential is set
        $clearIdx = $s.IndexOf('Remove-Item Env:ANTHROPIC_API_KEY')
        $setIdx   = $s.IndexOf('$env:CLAUDE_CODE_OAUTH_TOKEN=')
        $clearIdx | Should -BeLessThan $setIdx
    }
    It 'rejects an auth-var name that could inject into the spawned command' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        { Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt' 'abios-parallel' "X'); rm -rf /; #" } | Should -Throw
    }
    It 'escapes single quotes in the briefing path (no literal break / injection)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' "C:\O'Brien\brief.txt"
        $p.launchScript | Should -Match "O''Brien"
    }
}

Describe 'Build-WorktreeLaunch adapter parity' {
    # GOLDEN fixture captured from the pre-refactor Build-WorktreeLaunch for a claude
    # launch of issue 42 (brief C:\b\briefing-42.txt). The adapter-driven refactor MUST
    # keep the claude launchScript + args byte-identical to these constants.
    BeforeAll {
        $script:GoldenLaunchScript = @(
            "Remove-Item Env:ANTHROPIC_API_KEY,Env:ANTHROPIC_AUTH_TOKEN,Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue"
            "`$env:ANTHROPIC_API_KEY=[Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY','User')"
            "Remove-Item Env:CLAUDECODE,Env:CLAUDE_CODE_SESSION_ID,Env:CLAUDE_CODE_CHILD_SESSION,Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue"
            "claude -p (Get-Content -Raw -LiteralPath 'C:\b\briefing-42.txt') --permission-mode bypassPermissions --no-session-persistence --verbose"
        ) -join "`r`n"
        $script:GoldenWtArgs = @('-w', 'abios-parallel', 'new-tab', '--title', 'issue-42',
                                 '--startingDirectory', 'C:\wt\issue-42', 'pwsh', '-NoExit', '-File', 'C:\b\launch-42.ps1')
    }

    It 'exposes a -Cli parameter (adapter selector) defaulting to claude' {
        $cmd = Get-Command Build-WorktreeLaunch
        $cmd.Parameters.ContainsKey('Cli') | Should -BeTrue
        # the added selector must be appended, keeping the 5 original positionals in order
        $cmd.Parameters['Cli'].ParameterType | Should -Be ([string])
    }
    It 'produces a launchScript byte-identical to the golden when -Cli claude is explicit' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 42 'C:\wt\issue-42' 'C:\b\briefing-42.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude'
        $p.launchScript | Should -BeExactly $script:GoldenLaunchScript
    }
    It 'produces a launchScript byte-identical to the golden when -Cli is omitted (default claude)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 42 'C:\wt\issue-42' 'C:\b\briefing-42.txt' 'abios-parallel' 'ANTHROPIC_API_KEY'
        $p.launchScript | Should -BeExactly $script:GoldenLaunchScript
    }
    It 'produces args byte-identical to the golden wt args (explicit claude)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 42 'C:\wt\issue-42' 'C:\b\briefing-42.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude'
        $p.args.Count            | Should -Be $script:GoldenWtArgs.Count
        ($p.args -join "`n")     | Should -BeExactly ($script:GoldenWtArgs -join "`n")
    }
    It 'produces args byte-identical to the golden wt args (default claude)' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { [pscustomobject]@{ Name = 'wt' } }
        $p = Build-WorktreeLaunch 42 'C:\wt\issue-42' 'C:\b\briefing-42.txt' 'abios-parallel' 'ANTHROPIC_API_KEY'
        $p.args.Count            | Should -Be $script:GoldenWtArgs.Count
        ($p.args -join "`n")     | Should -BeExactly ($script:GoldenWtArgs -join "`n")
    }
    It 'default (no -Cli) still yields a claude -p launch script' {
        Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null }
        $p = Build-WorktreeLaunch 12 'C:\wt' 'C:\brief.txt'
        $p.launchScript | Should -Match 'claude -p '
    }
}

Describe 'New-FleetSessionMarker (reaper fingerprint token)' {
    It 'builds a <issue>-<runId> marker' {
        New-FleetSessionMarker 42 'abc123' | Should -Be '42-abc123'
    }
    It 'strips characters that are unsafe in an env value / -like match' {
        New-FleetSessionMarker 7 "a b'; rm/-x" | Should -Be '7-abrmx'
    }
    It 'is a bare token safe to embed and to match by -like (no quotes/spaces)' {
        New-FleetSessionMarker 190 (New-FleetRunId) | Should -Match '^\d+-[A-Za-z0-9]+$'
    }
    It 'New-FleetRunId yields an 8-char lowercase-hex token' {
        New-FleetRunId | Should -Match '^[0-9a-f]{8}$'
    }
}

Describe 'Build-WorktreeLaunch fleet marker (ABIOS_FLEET_SESSION)' {
    BeforeAll { Mock Get-Command -ParameterFilter { $Name -eq 'wt' } -MockWith { $null } }
    It 'stamps ABIOS_FLEET_SESSION with the given marker when -FleetSession is passed' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' '42-abc123'
        $p.launchScript | Should -Match "\`$env:ABIOS_FLEET_SESSION='42-abc123'"
    }
    It 'sets the marker BEFORE the CLI run line so the child + grandchild inherit it' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' '42-abc123'
        $markerIdx = ($p.launchScript -split "`r?`n" | Select-String 'ABIOS_FLEET_SESSION').LineNumber
        $runIdx    = ($p.launchScript -split "`r?`n" | Select-String 'claude -p ').LineNumber
        $markerIdx | Should -BeLessThan $runIdx
    }
    It 'surfaces the marker on the returned plan object' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' '42-abc123'
        $p.fleetSession | Should -Be '42-abc123'
    }
    It 'stamps every adapter, not just claude (adapter-agnostic prefix)' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'gemini' '42-abc123'
        $p.launchScript | Should -Match "ABIOS_FLEET_SESSION='42-abc123'"
        $p.launchScript | Should -Match 'gemini -p '
    }
    It 'adds NOTHING when -FleetSession is omitted (golden parity preserved)' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude'
        $p.launchScript | Should -Not -Match 'ABIOS_FLEET_SESSION'
        $p.fleetSession | Should -BeNullOrEmpty
    }
    It 'rejects a marker with injection characters (defense in depth)' {
        { Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' "x'; rm -rf /; #" } |
            Should -Throw
    }
    It 'redirects the session stream to the log via Start-Transcript when -logPath is set (#198)' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' '42-abc123' 'C:\st\logs\issue-42.log'
        $p.launchScript | Should -Match 'Start-Transcript -Path ''C:\\st\\logs\\issue-42\.log'''
        $p.launchScript | Should -Match 'New-Item -ItemType Directory -Force'
    }
    It 'adds no transcript when -logPath is omitted (golden parity preserved)' {
        $p = Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude'
        $p.launchScript | Should -Not -Match 'Start-Transcript'
    }
    It 'rejects an underscore (WQL LIKE single-char wildcard - unsafe as a fingerprint)' {
        { Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' '42_abc' } |
            Should -Throw
    }
    It 'rejects a marker that is not <issue>-<runId> shaped' {
        { Build-WorktreeLaunch 42 'C:\wt' 'C:\brief.txt' 'abios-parallel' 'ANTHROPIC_API_KEY' 'claude' 'abc-123' } |
            Should -Throw
    }
}

Describe 'Get-BranchDriftWarning (foreign-checkout guard)' {
    BeforeAll {
        # Build a session-registry entry shaped like Write-SessionRegistryEntry writes.
        function New-Session {
            param([int]$Issue, [string]$Branch, [string]$WorkPath, [int]$SessPid, [string]$Started = '2026-07-07 10:00')
            [pscustomobject]@{ issue = $Issue; repo = 'o/r'; branch = $Branch; workPath = $WorkPath; sessionPid = $SessPid; started = $Started }
        }
    }

    It 'returns null when the registry has no session for this PID' {
        Get-BranchDriftWarning -Sessions @() -SessionPid 100 -CurrentBranch 'issue-1-x' -CurrentPath 'C:\repo' | Should -BeNullOrEmpty
    }
    It 'returns null on a detached HEAD (no current branch to compare)' {
        $s = @(New-Session 1 'issue-1-x' 'C:\repo' 100)
        Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch '' -CurrentPath 'C:\repo' | Should -BeNullOrEmpty
    }
    It 'returns null when HEAD still matches the branch the session started here' {
        $s = @(New-Session 1 'issue-1-x' 'C:\repo' 100)
        Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'issue-1-x' -CurrentPath 'C:\repo' | Should -BeNullOrEmpty
    }
    It 'WARNS when HEAD drifted away from the started branch (the foreign-hook case)' {
        $s = @(New-Session 163 'issue-163-guard' 'C:\repo' 100)
        $w = Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'issue-180-other' -CurrentPath 'C:\repo'
        $w | Should -Match '#163'
        $w | Should -Match 'issue-163-guard'          # names the branch to return to
        $w | Should -Match 'git checkout issue-163-guard'
    }
    It 'ignores entries belonging to a different session PID' {
        $s = @(New-Session 1 'issue-1-x' 'C:\repo' 999)
        Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'main' -CurrentPath 'C:\repo' | Should -BeNullOrEmpty
    }
    It 'ignores a session started in a DIFFERENT working copy (a worktree elsewhere)' {
        $s = @(New-Session 1 'issue-1-x' 'C:\repo--worktrees\issue-1' 100)
        Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'main' -CurrentPath 'C:\repo' | Should -BeNullOrEmpty
    }
    It 'picks the most-recently-started in-place issue when several share the working copy' {
        $s = @(
            New-Session 1 'issue-1-old' 'C:\repo' 100 '2026-07-07 09:00'
            New-Session 2 'issue-2-new' 'C:\repo' 100 '2026-07-07 11:00'
        )
        $w = Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'main' -CurrentPath 'C:\repo'
        $w | Should -Match '#2'
        $w | Should -Not -Match '#1'
    }
    It 'matches the working path tolerant of trailing slash and case' {
        $s = @(New-Session 1 'issue-1-x' 'C:\Repo\' 100)
        Get-BranchDriftWarning -Sessions $s -SessionPid 100 -CurrentBranch 'issue-1-x' -CurrentPath 'c:\repo' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-IssueStart safety refusals + dry-run' {
    BeforeEach {
        Mock Get-IssueBlockers   { @() }        # not blocked unless a test overrides
        Mock Get-LastClaim       { '' }         # never hit the network for the claim
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @() } }  # no prior work
    }

    It 'skips a CLOSED issue without starting it' {
        Mock Get-BoardItem { New-FakeItem -State 'CLOSED' }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'CERRADO'
    }

    It 'skips an issue that is not on the board' {
        Mock Get-BoardItem { $null }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'no esta en el board'
    }

    It 'skips a blocked issue (and reports the blocker)' {
        Mock Get-BoardItem     { New-FakeItem }
        Mock Get-IssueBlockers { @("label 'blocked' presente") }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'BLOQUEADO'
        $r.skipped | Should -Match 'blocked'
    }

    It 'respects -IgnoreBlocked (a blocked issue is no longer skipped for that reason)' {
        Mock Get-BoardItem     { New-FakeItem }
        Mock Get-IssueBlockers { @("label 'blocked' presente") }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me' -IgnoreBlocked -DryRunStart
        $r.skipped | Should -Be ''
        $r.dryRun  | Should -BeTrue
    }

    It 'skips an issue already In Progress + assigned (multi-session lock)' {
        Mock Get-BoardItem { New-FakeItem -Status 'In Progress' -Assignees @('bob') }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'OCUPADO'
    }

    It '-TakeOver overrides the lock (reaches the plan instead of skipping)' {
        Mock Get-BoardItem { New-FakeItem -Status 'In Progress' -Assignees @('bob') }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me' -TakeOver -DryRunStart
        $r.skipped | Should -Be ''
        $r.dryRun  | Should -BeTrue
    }

    It 'plans (does not mutate) a clean issue under -DryRunStart' {
        Mock Get-BoardItem { New-FakeItem -Title 'Add a widget' }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me' -DryRunStart
        $r.started | Should -BeFalse
        $r.dryRun  | Should -BeTrue
        $r.skipped | Should -Be ''
        $r.branch  | Should -Match '^issue-1-'
    }

    It 'refuses an issue with a MERGED PR even without a claim (#236)' {
        Mock Get-BoardItem       { New-FakeItem }   # Backlog, unassigned - old lock would pass
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @([pscustomobject]@{ number = 9; state = 'MERGED' }); commits = @() } }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'YA TRABAJADO'
        $r.skipped | Should -Match 'MERGED'
    }

    It 'refuses an issue with an integrated commit citing it (#236)' {
        Mock Get-BoardItem       { New-FakeItem }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @([pscustomobject]@{ sha = 'abcdef1234' }) } }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'YA TRABAJADO'
    }

    It '-TakeOver overrides the PR/commit refusal (reaches the plan)' {
        Mock Get-BoardItem       { New-FakeItem }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @([pscustomobject]@{ number = 9; state = 'MERGED' }); commits = @() } }
        $r = Invoke-IssueStart -IssueNum 1 -Ctx $script:Ctx -Owner 'me' -TakeOver -DryRunStart
        $r.skipped | Should -Be ''
        $r.dryRun  | Should -BeTrue
    }
}

Describe 'Format-ClaimFingerprint (single source of the [abios-claim] format)' {
    It 'builds a claim line with the branch tail' {
        $s = Format-ClaimFingerprint -Note 'claim' -Computer 'BOX' -ProcessId 42 -Date '2026-07-13 10:00' -Branch 'issue-1-x'
        $s | Should -Be '[abios-claim] claim por sesion Claude en BOX (PID 42) - 2026-07-13 10:00 - rama issue-1-x'
    }
    It 'omits the branch tail when no branch is given (LOCK/UNLOCK)' {
        $s = Format-ClaimFingerprint -Note 'LOCK' -Computer 'BOX' -ProcessId 42 -Date '2026-07-13 10:00'
        $s | Should -Be '[abios-claim] LOCK por sesion Claude en BOX (PID 42) - 2026-07-13 10:00'
        $s | Should -Not -Match 'rama'
    }
}

Describe 'Get-PriorWorkRefusal (PR/commit-aware -Start refusal, #236)' {
    It 'returns no refusal when there is no prior work' {
        Get-PriorWorkRefusal -Prs @() -Commits @() | Should -Be ''
    }
    It 'refuses on a MERGED PR' {
        $r = Get-PriorWorkRefusal -Prs @([pscustomobject]@{ number = 9; state = 'MERGED' }) -Commits @()
        $r | Should -Match 'MERGED'
        $r | Should -Match '#9'
    }
    It 'refuses on an integrated commit' {
        $r = Get-PriorWorkRefusal -Prs @() -Commits @([pscustomobject]@{ sha = 'abcdef1234567' })
        $r | Should -Match 'commit'
        $r | Should -Match 'abcdef1'      # short sha
    }
    It 'refuses on an OPEN PR (mid-flight)' {
        $r = Get-PriorWorkRefusal -Prs @([pscustomobject]@{ number = 7; state = 'OPEN' }) -Commits @()
        $r | Should -Match 'abierto'
        $r | Should -Match '#7'
    }
    It 'ignores a CLOSED-unmerged PR (abandoned attempt must not block)' {
        Get-PriorWorkRefusal -Prs @([pscustomobject]@{ number = 3; state = 'CLOSED' }) -Commits @() | Should -Be ''
    }
    It 'prefers the MERGED-PR reason over an OPEN PR' {
        $r = Get-PriorWorkRefusal -Prs @(
            [pscustomobject]@{ number = 7; state = 'OPEN' },
            [pscustomobject]@{ number = 9; state = 'MERGED' }
        ) -Commits @()
        $r | Should -Match 'MERGED'
    }
}

Describe 'Get-CliAdapters' {
    It "returns claude as the default adapter with all required fields" {
        $adapters = Get-CliAdapters
        $claude = $adapters | Where-Object { $_.Name -eq 'claude' }
        $claude              | Should -Not -BeNullOrEmpty
        $claude.Command      | Should -Be 'claude'
        $claude.Kind         | Should -Be 'repl'
        $claude.IsDefault    | Should -BeTrue
        $claude.BuildLaunch  | Should -BeOfType ([scriptblock])
        $claude.Probe        | Should -BeOfType ([scriptblock])
    }
    It "includes all five CLIs by name" {
        (Get-CliAdapters).Name | Should -Contain 'gemini'
        (Get-CliAdapters).Name | Should -Contain 'jules'
        (Get-CliAdapters).Name | Should -Contain 'codex'
        (Get-CliAdapters).Name | Should -Contain 'copilot'
    }
    It "marks exactly one adapter as default" {
        @(Get-CliAdapters | Where-Object { $_.IsDefault }).Count | Should -Be 1
    }
}

Describe 'Get-CliProbeStatus' {
    It 'returns ok on exit 0' {
        Get-CliProbeStatus -ExitCode 0 -Stderr "" | Should -Be 'ok'
    }
    It 'returns no-quota on a rate-limit/quota message' {
        Get-CliProbeStatus -ExitCode 1 -Stderr "Error: 429 rate limit exceeded" | Should -Be 'no-quota'
        Get-CliProbeStatus -ExitCode 1 -Stderr "quota exceeded for this project" | Should -Be 'no-quota'
    }
    It 'returns auth on a 401/authentication message' {
        Get-CliProbeStatus -ExitCode 1 -Stderr "401 Unauthorized: please login" | Should -Be 'auth'
    }
    It 'returns error on any other non-zero exit' {
        Get-CliProbeStatus -ExitCode 1 -Stderr "some unexpected failure" | Should -Be 'error'
    }
    It 'catches quota error even on exit 0' {
        Get-CliProbeStatus -ExitCode 0 -Stderr "quota exceeded" | Should -Be 'no-quota'
    }
    It 'catches auth error even on exit 0' {
        Get-CliProbeStatus -ExitCode 0 -Stderr "not logged in" | Should -Be 'auth'
    }
}

Describe 'Invoke-CliProbe timeout' {
    It 'returns error when the command exceeds the timeout' {
        Invoke-CliProbe @('pwsh', '-NoProfile', '-Command', 'Start-Sleep 5') -TimeoutSec 1 | Should -Be 'error'
    }
    It 'classifies a fast command' {
        Invoke-CliProbe @('pwsh', '-NoProfile', '-Command', 'exit 0') | Should -Be 'ok'
    }
}

Describe 'Test-CliAvailability' {
    It 'reports not-installed when the command is absent' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'codex' }
        $r = Test-CliAvailability -Adapter ([PSCustomObject]@{ Name='codex'; Command='codex'; Probe={ param($ctx) 'ok' } })
        $r.Status | Should -Be 'not-installed'
    }
    It 'runs the probe when installed and returns its status' {
        Mock Get-Command { [PSCustomObject]@{ Source='C:\x\gemini.exe' } } -ParameterFilter { $Name -eq 'gemini' }
        $r = Test-CliAvailability -Adapter ([PSCustomObject]@{ Name='gemini'; Command='gemini'; Probe={ param($ctx) 'no-quota' } })
        $r.Status | Should -Be 'no-quota'
        $r.Cli    | Should -Be 'gemini'
    }
}

Describe 'Resolve-LaunchCli' {
    It 'returns the chosen CLI when it is available' {
        Resolve-LaunchCli -Chosen 'gemini' -Availability @{ gemini='ok'; claude='ok' } | Should -Be 'gemini'
    }
    It 'falls back to claude when the chosen CLI is unavailable' {
        Resolve-LaunchCli -Chosen 'gemini' -Availability @{ gemini='no-quota'; claude='ok' } | Should -Be 'claude'
    }
    It 'falls back to claude when the chosen CLI is missing from the map' {
        Resolve-LaunchCli -Chosen 'codex' -Availability @{ claude='ok' } | Should -Be 'claude'
    }
}

Describe 'Resolve-IssueCliMap' {
    It 'keeps a valid available choice' {
        $map = Resolve-IssueCliMap -Issues @(12,14) -Choices @{ 12='gemini'; 14='claude' } -Availability @{ gemini='ok'; claude='ok' }
        $map[12] | Should -Be 'gemini'
        $map[14] | Should -Be 'claude'
    }
    It 'coerces an unavailable choice to claude' {
        $map = Resolve-IssueCliMap -Issues @(12) -Choices @{ 12='codex' } -Availability @{ claude='ok' }
        $map[12] | Should -Be 'claude'
    }
    It 'defaults an unspecified issue to claude' {
        $map = Resolve-IssueCliMap -Issues @(99) -Choices @{} -Availability @{ claude='ok' }
        $map[99] | Should -Be 'claude'
    }
}
Describe 'Show-CliAvailability' {
    It 'renders one line per CLI with its status' {
        $out = Show-CliAvailability -Availability @{ claude='ok'; gemini='no-quota' } | Out-String
        $out | Should -Match 'claude'
        $out | Should -Match 'no-quota'
    }
}

Describe 'Build-FleetPlan' {
    It 'pairs each started issue with its resolved CLI' {
        $started = @(
            [PSCustomObject]@{ issue=12; repo='o/r'; branch='issue-12-x'; workPath='C:\wt\12' }
            [PSCustomObject]@{ issue=14; repo='o/r'; branch='issue-14-y'; workPath='C:\wt\14' }
        )
        $map = @{ 12='gemini'; 14='claude' }
        $plan = Build-FleetPlan -Started $started -CliMap $map
        ($plan | Where-Object issue -eq 12).cli | Should -Be 'gemini'
        ($plan | Where-Object issue -eq 14).cli | Should -Be 'claude'
    }
    It 'defaults to claude when an issue is absent from the map' {
        $started = @([PSCustomObject]@{ issue=7; repo='o/r'; branch='b'; workPath='C:\wt\7' })
        (Build-FleetPlan -Started $started -CliMap @{})[0].cli | Should -Be 'claude'
    }
}

Describe 'Get-MachineCapacityCore (pure capacity math)' {
    It 'averages LoadPercentage across CPU sockets' {
        (Get-MachineCapacityCore @(20, 40) 4194304 8388608 8).CpuLoadPercent | Should -Be 30
    }
    It 'treats no readings as 0% (momentary null LoadPercentage)' {
        (Get-MachineCapacityCore @() 4194304 8388608 8).CpuLoadPercent | Should -Be 0
    }
    It 'ignores null entries when averaging' {
        (Get-MachineCapacityCore @(50, $null) 4194304 8388608 8).CpuLoadPercent | Should -Be 50
    }
    It 'converts free/total physical KB to GB' {
        $c = Get-MachineCapacityCore @(0) 4194304 16777216 8   # 4 GB free, 16 GB total (in KB)
        $c.FreeRamGB  | Should -Be 4
        $c.TotalRamGB | Should -Be 16
    }
    It 'passes the logical core count through' {
        (Get-MachineCapacityCore @(0) 1048576 2097152 12).Cores | Should -Be 12
    }
    It 'never reports a negative CPU or RAM' {
        $c = Get-MachineCapacityCore @() 0 0 1
        $c.CpuLoadPercent | Should -BeGreaterOrEqual 0
        $c.FreeRamGB      | Should -BeGreaterOrEqual 0
    }
}

Describe 'Get-DispatchPlan (wave size from capacity + caps)' {
    It 'bounds the wave by free RAM / per-session budget' {
        $p = Get-DispatchPlan -FreeRamGB 5 -Cores 16 -Pending 10 -PerSessionGB 2
        $p.WaveSize | Should -Be 2          # floor(5/2)=2, well under cores-2 and pending
        $p.BoundBy  | Should -Be 'ram'
    }
    It 'bounds the wave by cores-2 (the platform concurrency cap)' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 4 -Pending 10 -PerSessionGB 2
        $p.WaveSize | Should -Be 2          # cores-2 = 2
        $p.BoundBy  | Should -Be 'cores'
    }
    It 'bounds the wave by an explicit -MaxConcurrent' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 10 -PerSessionGB 2 -MaxConcurrent 3
        $p.WaveSize | Should -Be 3
        $p.BoundBy  | Should -Be 'maxconcurrent'
    }
    It 'never launches more than the pending count' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 1 -PerSessionGB 2
        $p.WaveSize | Should -Be 1
        $p.BoundBy  | Should -Be 'pending'
    }
    It 'subtracts the sessions already running from the free slots' {
        # allowed concurrent = min(floor(100/2)=50, cores-2=14, none) = 14; running 12 -> 2 free
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 10 -Running 12 -PerSessionGB 2
        $p.WaveSize | Should -Be 2
    }
    It 'guarantees forward progress: >=1 when nothing runs and RAM looks exhausted' {
        $p = Get-DispatchPlan -FreeRamGB 0.5 -Cores 16 -Pending 3 -Running 0 -PerSessionGB 2
        $p.WaveSize | Should -Be 1          # ramCap floor=0, but launch 1 to avoid deadlock
    }
    It 'returns 0 when the concurrency ceiling is already full' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 5 -Running 14 -PerSessionGB 2
        $p.WaveSize | Should -Be 0
    }
    It 'keeps cores-2 at a floor of 1 on a tiny box' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 1 -Pending 5 -Running 0 -PerSessionGB 2
        $p.WaveSize | Should -Be 1
    }
    It 'never exposes a negative ceiling on a corrupt (negative) RAM reading' {
        $p = Get-DispatchPlan -FreeRamGB -1 -Cores 16 -Pending 0 -PerSessionGB 2
        $p.RamCap      | Should -BeGreaterOrEqual 0
        $p.Concurrency | Should -BeGreaterOrEqual 0
        $p.WaveSize    | Should -Be 0
    }
    It 'labels an empty queue as pending-bound, not capacity-bound' {
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 0 -Running 14 -PerSessionGB 2
        $p.WaveSize | Should -Be 0
        $p.BoundBy  | Should -Be 'pending'
    }
    It 'does not let a negative running count inflate the wave past the ceiling' {
        # ceiling = min(floor(100/2)=50, cores-2=14) = 14; a corrupt Running=-5 must NOT
        # read as 19 free slots.
        $p = Get-DispatchPlan -FreeRamGB 100 -Cores 16 -Pending 30 -Running -5 -PerSessionGB 2
        $p.WaveSize | Should -Be 14
    }
}

Describe 'Test-SlotFree (governor wait predicate)' {
    It 'frees when a session finished (running dropped below the baseline)' {
        Test-SlotFree 3 2 99 85 | Should -BeTrue
    }
    It 'frees when the CPU cooled below the threshold' {
        Test-SlotFree 3 3 40 85 | Should -BeTrue
    }
    It 'keeps waiting when nothing finished and the CPU is still hot' {
        Test-SlotFree 3 3 95 85 | Should -BeFalse
    }
}

Describe 'Invoke-FleetDispatch (governor loop)' {
    It 'launches the whole queue across waves paced by capacity' {
        $script:running = 0
        $launch = { param($item, $cli) $script:running++ ; $cli }   # hook returns the actual CLI
        $r = Invoke-FleetDispatch -Queue @(
                [pscustomobject]@{ issue=1; cli='claude' }, [pscustomobject]@{ issue=2; cli='claude' }
                [pscustomobject]@{ issue=3; cli='claude' }, [pscustomobject]@{ issue=4; cli='claude' }
                [pscustomobject]@{ issue=5; cli='claude' }
             ) -PerSessionGB 2 -LaunchSession $launch `
               -GetCapacity  { [pscustomobject]@{ FreeRamGB=100; Cores=4 } } `
               -CountRunning { $script:running } `
               -WaitForSlot  { $script:running = 0 }   # all sessions finish while we wait
        @($r).Count | Should -Be 5
        ($r.issue | Sort-Object) | Should -Be @(1,2,3,4,5)
        # ceiling = min(floor(100/2)=50, cores-2=2) = 2 -> waves of 2, 2, 1
        ($r | Group-Object wave | ForEach-Object Count) | Should -Be @(2,2,1)
    }
    It 'reroutes a known no-quota CLI to the claude fallback (runtime backoff)' {
        $r = Invoke-FleetDispatch -Queue @([pscustomobject]@{ issue=9; cli='gemini' }) `
               -NoQuotaClis @{ gemini = $true } -LaunchSession { param($item, $cli) $cli } `
               -GetCapacity  { [pscustomobject]@{ FreeRamGB=100; Cores=16 } } `
               -CountRunning { 0 } -WaitForSlot { }
        $r[0].cli | Should -Be 'claude'
    }
    It 'passes an available CLI through unchanged' {
        $r = Invoke-FleetDispatch -Queue @([pscustomobject]@{ issue=9; cli='gemini' }) `
               -LaunchSession { param($item,$cli) $cli } `
               -GetCapacity  { [pscustomobject]@{ FreeRamGB=100; Cores=16 } } `
               -CountRunning { 0 } -WaitForSlot { }
        $r[0].cli | Should -Be 'gemini'
    }
    It 'records the CLI the hook actually launched, not the pre-launch guess' {
        # The hook re-resolves availability and returns the CLI it really used.
        $r = Invoke-FleetDispatch -Queue @([pscustomobject]@{ issue=9; cli='gemini' }) `
               -LaunchSession { param($item,$cli) 'claude' } `
               -GetCapacity  { [pscustomobject]@{ FreeRamGB=100; Cores=16 } } `
               -CountRunning { 0 } -WaitForSlot { }
        $r[0].cli | Should -Be 'claude'
    }
    It 'terminates (does not hang/spin) when slots never free' {
        # ceiling full forever + a no-op waiter: the stall guard must break, not loop.
        $r = Invoke-FleetDispatch -Queue @([pscustomobject]@{ issue=1; cli='claude' }) `
               -MaxStalls 3 -LaunchSession { param($i,$c) $c } `
               -GetCapacity  { [pscustomobject]@{ FreeRamGB=100; Cores=16 } } `
               -CountRunning { 999 } -WaitForSlot { }   # always full, waiting frees nothing
        @($r).Count | Should -Be 0
    }
    It 'requires a LaunchSession hook' {
        { Invoke-FleetDispatch -Queue @([pscustomobject]@{ issue=1; cli='claude' }) } | Should -Throw
    }
    It 'does nothing on an empty queue' {
        @(Invoke-FleetDispatch -Queue @() -LaunchSession { param($i,$c) $c }).Count | Should -Be 0
    }
}

Describe 'Get-AncestorChain (self + ancestors, cycle-safe)' {
    It 'walks ParentProcessId from the start PID up to the root' {
        Get-AncestorChain 100 @{ 100=50; 50=10; 10=0 } | Should -Be @(100, 50, 10)
    }
    It 'includes the start PID itself (it is guarded too)' {
        (Get-AncestorChain 7 @{ 7=0 })[0] | Should -Be 7
    }
    It 'stops on a cycle instead of looping forever' {
        Get-AncestorChain 5 @{ 5=6; 6=5 } | Should -Be @(5, 6)
    }
    It 'returns just the start PID when it has no known parent' {
        Get-AncestorChain 42 @{} | Should -Be @(42)
    }
}

Describe 'Get-SessionGuardSet (never-kill set)' {
    It 'is the current PID plus its ancestor chain' {
        Mock Get-ProcessParentMap -MockWith { @{ 200=100; 100=1; 1=0 } }
        $g = Get-SessionGuardSet 200
        $g | Should -Contain 200
        $g | Should -Contain 100
        $g | Should -Contain 1
    }
}

Describe 'Remove-GuardedTargets (subtract the guard set)' {
    It 'drops any target that is in the guard set' {
        Remove-GuardedTargets @(1,2,3,4) @(2,4) | Should -Be @(1,3)
    }
    It 'returns an empty array when every target is guarded' {
        @(Remove-GuardedTargets @(5,6) @(5,6,7)).Count | Should -Be 0
    }
    It 'passes everything through when the guard set is empty' {
        Remove-GuardedTargets @(1,2) @() | Should -Be @(1,2)
    }
}

Describe 'Get-DescendantPids (subtree, cycle-safe)' {
    It 'returns every transitive child of the root' {
        (Get-DescendantPids 10 @{ 20=10; 30=20; 40=10 } | Sort-Object) | Should -Be @(20, 30, 40)
    }
    It 'returns only the direct+indirect children of the given node' {
        Get-DescendantPids 20 @{ 20=10; 30=20; 40=10 } | Should -Be @(30)
    }
    It 'returns empty for a leaf' {
        @(Get-DescendantPids 40 @{ 20=10; 40=10 }).Count | Should -Be 0
    }
    It 'does not loop on a cycle' {
        { Get-DescendantPids 1 @{ 1=2; 2=1 } } | Should -Not -Throw
    }
}

Describe 'Stop-ProcessTree (tree kill, fail-safe self-exclusion)' {
    # A tiny process tree: 500 is self; its ancestor chain is 500->300->1. 700 is an
    # unrelated fleet descendant (child of 600). 900 is 700's child.
    BeforeAll {
        $script:PMap = @{ 500=300; 300=1; 1=0; 600=1; 700=600; 900=700 }
    }
    It 'REFUSES to kill the current session PID (computed guard, not caller-supplied)' {
        $r = Stop-ProcessTree -TargetPid 500 -SelfPid 500 -ParentMap $script:PMap -DryRun
        $r.Refused | Should -BeTrue
        $r.Killed  | Should -BeFalse
    }
    It 'REFUSES to kill an ancestor of the current session even with an empty -Guard' {
        (Stop-ProcessTree -TargetPid 300 -SelfPid 500 -ParentMap $script:PMap -DryRun).Refused | Should -BeTrue
    }
    It 'REFUSES when the target SUBTREE contains a guarded PID (taskkill /T kills descendants)' {
        # Kill 600 would tree-kill its child 700... but say 700 is in the caller guard.
        $r = Stop-ProcessTree -TargetPid 600 -SelfPid 500 -ParentMap $script:PMap -Guard @(700) -DryRun
        $r.Refused | Should -BeTrue
    }
    It 'PLANS a tree-deep force kill for a genuinely unrelated PID' {
        $r = Stop-ProcessTree -TargetPid 700 -SelfPid 500 -ParentMap $script:PMap -DryRun
        $r.Refused | Should -BeFalse
        $r.Command | Should -Match 'taskkill /PID 700 /T /F'
    }
    It 'FAILS CLOSED when the process map cannot be built (no guard can be verified)' {
        (Stop-ProcessTree -TargetPid 700 -SelfPid 500 -ParentMap @{} -DryRun).Refused | Should -BeTrue
    }
    It 'refuses a non-positive PID' {
        (Stop-ProcessTree -TargetPid 0 -ParentMap $script:PMap -DryRun).Refused | Should -BeTrue
    }
}

Describe 'Get-FleetIssueFromCommandLine (issue-precise fingerprint)' {
    It 'parses the issue from a launch-<n>.ps1 launcher' {
        Get-FleetIssueFromCommandLine 'pwsh -File C:\x\.agentic-board\launch-42.ps1' | Should -Be 42
    }
    It 'parses the issue from a briefing-<n>.txt read' {
        Get-FleetIssueFromCommandLine 'node claude -p (Get-Content briefing-7.txt)' | Should -Be 7
    }
    It 'parses the issue from a --worktrees\issue-<n> path' {
        Get-FleetIssueFromCommandLine 'C:\repo--worktrees\issue-13\...' | Should -Be 13
    }
    It 'returns 0 for an unrelated process' {
        Get-FleetIssueFromCommandLine 'C:\Windows\explorer.exe' | Should -Be 0
    }
    It 'does NOT match a keyword without digits (launch-server, not a fleet artifact)' {
        Get-FleetIssueFromCommandLine 'node C:\proj\launch-server.js' | Should -Be 0
    }
    It 'does NOT over-match a non-generated launch filename (launch-42-test.ps1)' {
        Get-FleetIssueFromCommandLine 'pwsh -File .\launch-42-test.ps1' | Should -Be 0
    }
    It 'does NOT over-match a bare issue-<n> outside a worktree path (reproducer script)' {
        Get-FleetIssueFromCommandLine 'node tools/issue-123-reproducer.js' | Should -Be 0
    }
    It 'is 0 for an empty command line' {
        Get-FleetIssueFromCommandLine '' | Should -Be 0
    }
}

Describe 'Find-FleetOrphansCore (escaped, cross-checked by PID AND issue)' {
    BeforeAll {
        $script:Procs = @(
            [pscustomobject]@{ ProcessId=700; CommandLine='pwsh -File C:\wt\launch-5.ps1' }   # issue 5
            [pscustomobject]@{ ProcessId=800; CommandLine='pwsh -File C:\wt\launch-6.ps1' }   # issue 6
            [pscustomobject]@{ ProcessId=900; CommandLine='C:\Windows\notepad.exe' }           # not fleet
        )
    }
    It 'returns fleet processes that are neither a live PID nor a live issue' {
        $o = Find-FleetOrphansCore $script:Procs @() @(6)   # issue 6 live, 5 escaped
        @($o).Count     | Should -Be 1
        $o[0].ProcessId | Should -Be 700
    }
    It 'does NOT reap a live wt session whose issue is tracked under a different (host) PID' {
        # 700 is the real spawned pwsh for issue 5; the registry tracked the host PID, not 700,
        # but issue 5 IS a live session -> must be excluded by the issue cross-check.
        @(Find-FleetOrphansCore $script:Procs @() @(5, 6)).ProcessId | Should -Not -Contain 700
    }
    It 'excludes a process whose exact PID is a live registry session' {
        @(Find-FleetOrphansCore $script:Procs @(700) @()).ProcessId | Should -Not -Contain 700
    }
    It 'ignores non-fleet processes entirely' {
        (Find-FleetOrphansCore $script:Procs @() @()).ProcessId | Should -Not -Contain 900
    }
}

Describe 'Invoke-FleetReap (guard-safe orphan/fleet kill)' {
    BeforeAll {
        # 500 is self (guarded via ParentMap 500->1); 700 is an orphan whose subtree holds
        # 750 - a LIVE registered session that must be protected.
        $script:RMap  = @{ 500=1; 1=0; 700=600; 600=1; 750=700 }
        $script:Cands = @(
            [pscustomobject]@{ ProcessId=700; CommandLine='pwsh launch-5.ps1' }
            [pscustomobject]@{ ProcessId=500; CommandLine='pwsh launch-9.ps1' }   # self - must survive
        )
    }
    # By default no live sessions in the fake registry (deterministic).
    BeforeEach { Mock Read-SessionRegistry -MockWith { @() } }

    It 'plans a kill for the orphan and REFUSES the guarded self under -DryRun' {
        $r = Invoke-FleetReap -Candidates $script:Cands -SelfPid 500 -ParentMap $script:RMap -DryRun
        ($r | Where-Object { $_.Pid -eq 700 }).Refused | Should -BeFalse
        ($r | Where-Object { $_.Pid -eq 500 }).Refused | Should -BeTrue
    }
    It 'FAIL-SAFE: protects a LIVE registry session in a candidate subtree even with NO -Guard' {
        # 750 (live per the registry) is a descendant of orphan 700; the reaper folds live
        # registry PIDs into the guard itself, so the kill is vetoed without any caller -Guard.
        Mock Read-SessionRegistry -MockWith { @([pscustomobject]@{ sessionPid = 750; issue = 5 }) }
        $r = Invoke-FleetReap -Candidates $script:Cands -SelfPid 500 -ParentMap $script:RMap -DryRun
        ($r | Where-Object { $_.Pid -eq 700 }).Refused | Should -BeTrue
    }
    It 'reports one result per candidate' {
        @(Invoke-FleetReap -Candidates $script:Cands -SelfPid 500 -ParentMap $script:RMap -DryRun).Count | Should -Be 2
    }
    It 'does nothing on an empty candidate set' {
        @(Invoke-FleetReap -Candidates @() -SelfPid 500 -ParentMap $script:RMap -DryRun).Count | Should -Be 0
    }
    It 'FAILS CLOSED when the session registry cannot be read (refuses every candidate)' {
        Mock Read-SessionRegistry -MockWith { throw 'registro corrupto' }
        $r = Invoke-FleetReap -Candidates $script:Cands -SelfPid 500 -ParentMap $script:RMap -DryRun
        @($r | Where-Object { -not $_.Refused }).Count | Should -Be 0
    }
    It '-KillLive (-KillAll): kills a tracked live session but STILL protects self' {
        # A live session at 750 (descendant of orphan 700). -KillAll must reap 700's tree
        # (incl. 750) yet never touch self (500).
        Mock Read-SessionRegistry -MockWith { @([pscustomobject]@{ sessionPid = 750; issue = 5 }) }
        $r = Invoke-FleetReap -Candidates $script:Cands -SelfPid 500 -ParentMap $script:RMap -KillLive -DryRun
        ($r | Where-Object { $_.Pid -eq 700 }).Refused | Should -BeFalse   # live session NOT protected
        ($r | Where-Object { $_.Pid -eq 500 }).Refused | Should -BeTrue    # self ALWAYS protected
    }
}

Describe 'Get-MachineCapacity (live wrapper wiring)' {
    It 'wires the CIM readings into the pure core' {
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Processor' } -MockWith {
            @([pscustomobject]@{ LoadPercentage = 10 }, [pscustomobject]@{ LoadPercentage = 30 })
        }
        Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } -MockWith {
            [pscustomobject]@{ FreePhysicalMemory = 4194304; TotalVisibleMemorySize = 8388608 }
        }
        $c = Get-MachineCapacity -LogicalCores 8
        $c.CpuLoadPercent | Should -Be 20
        $c.FreeRamGB      | Should -Be 4
        $c.TotalRamGB     | Should -Be 8
        $c.Cores          | Should -Be 8
    }
}

Describe 'Get-LogTailLines (dashboard log tail)' {
    BeforeAll {
        $script:LogFile = Join-Path $TestDrive 'issue-7.log'
        Set-Content -LiteralPath $script:LogFile -Value "l1`nl2`nl3`nl4`nl5" -Encoding UTF8
    }
    It 'returns the last N lines in order' {
        Get-LogTailLines $script:LogFile 2 | Should -Be @('l4', 'l5')
    }
    It 'returns all lines when the file is shorter than N' {
        (Get-LogTailLines $script:LogFile 99).Count | Should -Be 5
    }
    It 'returns an empty array for a missing file (no session log yet)' {
        @(Get-LogTailLines (Join-Path $TestDrive 'nope.log') 3).Count | Should -Be 0
    }
    It 'drops trailing blank lines' {
        $f = Join-Path $TestDrive 'trail.log'
        Set-Content -LiteralPath $f -Value "a`nb`n`n`n" -Encoding UTF8
        Get-LogTailLines $f 2 | Should -Be @('a', 'b')
    }
    It 'returns the single line intact when the tail is exactly one line ($start -eq $end slice)' {
        $f = Join-Path $TestDrive 'one.log'
        Set-Content -LiteralPath $f -Value "only" -Encoding UTF8
        # PS unwraps a 1-element result on capture; an indexing caller wraps with @(...).
        $r = @(Get-LogTailLines $f 3)
        $r.Count | Should -Be 1
        $r[0]    | Should -Be 'only'
    }
    It 'returns an empty array for a whitespace-only file' {
        $f = Join-Path $TestDrive 'blank.log'
        Set-Content -LiteralPath $f -Value "`n `n`n" -Encoding UTF8
        @(Get-LogTailLines $f 3).Count | Should -Be 0
    }
}

Describe 'Get-SessionMetrics (live PID CPU/RAM)' {
    It 'reports RAM (MB) and CPU (s) for a live PID' {
        Mock Get-Process -MockWith { [pscustomobject]@{ WorkingSet64 = 512MB; CPU = 12.4 } }
        $m = Get-SessionMetrics 1234
        $m.Alive | Should -BeTrue
        $m.RamMB | Should -Be 512
        $m.CpuSec | Should -Be 12
    }
    It 'reports not-alive for a dead PID' {
        Mock Get-Process -MockWith { $null }
        (Get-SessionMetrics 4321).Alive | Should -BeFalse
    }
}

Describe 'Format-SessionMetric (dashboard cell)' {
    It 'renders RAM + CPU for a live session' {
        $s = Format-SessionMetric ([pscustomobject]@{ Alive=$true; RamMB=512; CpuSec=12 })
        $s | Should -Match '512'
        $s | Should -Match 'MB'
        $s | Should -Match '12'
    }
    It 'renders a dead marker when the PID is gone' {
        Format-SessionMetric ([pscustomobject]@{ Alive=$false }) | Should -Match 'muerto'
    }
}

Describe 'Get-SessionLogPath (fleet log convention)' {
    It 'points at logs/issue-<n>.log under the state dir' {
        Mock Get-AbiosDir -MockWith { 'C:\repo\.agentic-board' }
        Get-SessionLogPath 42 | Should -Be 'C:\repo\.agentic-board\logs\issue-42.log'
    }
}

Describe 'non-claude adapters' {
    It 'gemini BuildLaunch uses -p and --approval-mode yolo --skip-trust' {
        $ctx = @{ BriefingFile = 'C:\b\brief.txt' }
        $s = & ((Get-CliAdapters | Where-Object Name -eq 'gemini').BuildLaunch) $ctx
        $s | Should -Match 'gemini -p'
        $s | Should -Match '--approval-mode yolo'
        $s | Should -Match '--skip-trust'
    }
    It 'codex BuildLaunch uses exec + --dangerously-bypass-approvals-and-sandbox with an stdin EOF guard' {
        $ctx = @{ BriefingFile = 'C:\b\brief.txt' }
        $s = & ((Get-CliAdapters | Where-Object Name -eq 'codex').BuildLaunch) $ctx
        $s | Should -Match '\$null \|.*codex exec .*--dangerously-bypass-approvals-and-sandbox'
        $s | Should -Match 'Get-Content'
    }
    It 'codex Probe uses login status (not exec, which hangs on stdin)' {
        ((Get-CliAdapters | Where-Object Name -eq 'codex').Probe).ToString() | Should -Match 'login.*status'
    }
    It 'jules Probe scopes to remote list --session' {
        ((Get-CliAdapters | Where-Object Name -eq 'jules').Probe).ToString() | Should -Match 'remote.*list.*session'
    }
    It 'copilot BuildLaunch uses -p + --allow-all' {
        $ctx = @{ BriefingFile = 'C:\b\brief.txt' }
        (& ((Get-CliAdapters | Where-Object Name -eq 'copilot').BuildLaunch) $ctx) | Should -Match 'copilot -p .* --allow-all'
    }
    It 'jules BuildLaunch dispatches jules new' {
        $ctx = @{ BriefingFile = 'C:\b\brief.txt' }
        (& ((Get-CliAdapters | Where-Object Name -eq 'jules').BuildLaunch) $ctx) | Should -Match 'jules new'
    }
    It 'claude probe returns ok (host CLI always available)' {
        (& (Get-CliAdapters | Where-Object Name -eq 'claude').Probe $null) | Should -Be 'ok'
    }
    It 'briefing path with a single quote is escaped in a non-claude adapter' {
        $ctx = @{ BriefingFile = "C:\Users\O'Brien\b.txt" }
        (& ((Get-CliAdapters | Where-Object Name -eq 'gemini').BuildLaunch) $ctx) | Should -Match "O''Brien"
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
    It 'threads each page endCursor into the next fetch (first cursor is empty)' {
        $script:seen = @()
        $fetch = {
            param($cursor)
            $script:seen += "$cursor"
            if (-not $cursor) { @{ nodes = @('a'); hasNext = $true;  endCursor = 'NEXT' } }
            else              { @{ nodes = @('b'); hasNext = $false; endCursor = $null } }
        }
        Get-AllPages $fetch | Out-Null
        $script:seen[0] | Should -Be ''
        $script:seen[1] | Should -Be 'NEXT'
    }
    It 'returns an empty array for a single empty page' {
        @(Get-AllPages { param($c) @{ nodes = @(); hasNext = $false; endCursor = $null } }).Count | Should -Be 0
    }
    It 'finds an issue that only appears on the SECOND page (the #246 regression)' {
        $fetch = {
            param($cursor)
            if (-not $cursor) {
                @{ nodes = @([pscustomobject]@{ content = [pscustomobject]@{ __typename='Issue'; number=1 } }); hasNext = $true; endCursor = 'p2' }
            } else {
                @{ nodes = @([pscustomobject]@{ content = [pscustomobject]@{ __typename='Issue'; number=239 } }); hasNext = $false; endCursor = $null }
            }
        }
        $all = @(Get-AllPages $fetch)
        ($all | Where-Object { $_.content.number -eq 239 }).Count | Should -Be 1
    }
}

Describe 'Get-SessionCompletion (watch completion predicate, #135)' {
    It 'is done when the PR is MERGED (head == our branch tip)' {
        $r = Get-SessionCompletion -PrState 'MERGED' -IssueState 'OPEN' -PidAlive $true `
            -PrHeadOid 'abc123' -BranchTip 'abc123'
        $r.done | Should -BeTrue; $r.reason | Should -Match 'merged'
    }
    It 'is done when the issue is CLOSED' {
        $r = Get-SessionCompletion -PrState 'OPEN' -IssueState 'CLOSED' -PidAlive $true
        $r.done | Should -BeTrue; $r.reason | Should -Match 'cerrado'
    }
    It 'is done when the host PID is dead' {
        $r = Get-SessionCompletion -PrState '' -IssueState 'OPEN' -PidAlive $false
        $r.done | Should -BeTrue; $r.reason | Should -Match 'termin'
    }
    It 'is NOT done while the PR is open, the issue open, and the PID alive' {
        (Get-SessionCompletion -PrState 'OPEN' -IssueState 'OPEN' -PidAlive $true).done | Should -BeFalse
    }
    It 'prefers the MERGED reason over pid-dead' {
        (Get-SessionCompletion -PrState 'MERGED' -IssueState 'OPEN' -PidAlive $false `
            -PrHeadOid 'abc123' -BranchTip 'abc123').reason | Should -Match 'merged'
    }
    It 'a STALE merged PR does NOT complete a LIVE session (it would force-remove its worktree)' {
        # Cleanup kills the shell and runs `git worktree remove --force`, so completing a live
        # session on someone else's merged PR would destroy its working state (Codex #275).
        $r = Get-SessionCompletion -PrState 'MERGED' -IssueState 'OPEN' -PidAlive $true `
            -PrHeadOid 'old111' -BranchTip 'new999'
        $r.done | Should -BeFalse
    }
    It 'a dead session with a STALE merged PR still completes, via the PID signal' {
        # Falling through must not strand the session: the PID/issue signals still finish it,
        # and merged=$false keeps the delete safe.
        $r = Get-SessionCompletion -PrState 'MERGED' -IssueState 'OPEN' -PidAlive $false `
            -PrHeadOid 'old111' -BranchTip 'new999'
        $r.done   | Should -BeTrue
        $r.reason | Should -Match 'termin'
        $r.merged | Should -BeFalse
    }
    # `merged` licenses the branch force-delete downstream (#273) - only a landed PR whose
    # head IS the tip we would delete earns it.
    It 'flags merged for a MERGED PR whose head is the branch tip' {
        (Get-SessionCompletion -PrState 'MERGED' -IssueState 'OPEN' -PidAlive $true `
            -PrHeadOid 'abc123' -BranchTip 'abc123').merged | Should -BeTrue
    }
    It 'does NOT flag merged when the issue closed without a merged PR' {
        (Get-SessionCompletion -PrState 'CLOSED' -IssueState 'CLOSED' -PidAlive $true).merged | Should -BeFalse
    }
    It 'does NOT flag merged when the session just died (the silent-data-loss case)' {
        (Get-SessionCompletion -PrState '' -IssueState 'OPEN' -PidAlive $false).merged | Should -BeFalse
    }
    It 'does NOT trust a STALE merged PR on a REUSED branch name (Codex #275)' {
        # -TakeOver re-runs reuse the deterministic issue-<n>-<slug> branch name. An OLD
        # merged PR must not vouch for the NEW tip, or a crashed session loses its commits.
        $r = Get-SessionCompletion -PrState 'MERGED' -IssueState 'CLOSED' -PidAlive $false `
            -PrHeadOid 'old111' -BranchTip 'new999'
        $r.done   | Should -BeTrue    # still finished (via the issue/PID signals)...
        $r.merged | Should -BeFalse   # ...but NOT licensed to force-delete
    }
    It 'does NOT flag merged when the PR head or the branch tip is unknown (fail safe)' {
        (Get-SessionCompletion -PrState 'MERGED' -PrHeadOid '' -BranchTip 'abc').merged | Should -BeFalse
        (Get-SessionCompletion -PrState 'MERGED' -PrHeadOid 'abc' -BranchTip '').merged | Should -BeFalse
    }
}

Describe 'Worktree registry helpers live here now (#289)' {
    # Moved from Board-Doctor.ps1: the doctor dot-sources THIS file, so both callers share one
    # verdict. The doctor's own suite still exercises them through that dot-source; these pin the
    # contract at the new home. Full parsing/matching coverage stays in Board-Doctor.Tests.ps1.
    It 'defines both helpers so the teardown below can reach them without a dot-source cycle' {
        Get-Command Get-WorktreeRecords          -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-WorktreeStillRegistered -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'blocks on the branch even when the path strings do not compare equal' {
        # The fail-open guarded since #287: git prints the long path, %TEMP% carries the 8.3 short
        # name, so the same directory yields two different strings.
        $p = "worktree C:/Users/Cristobal/AppData/Local/Temp/wt/w`nHEAD 1`nbranch refs/heads/issue-9-x`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path 'C:/Users/CRISTO~1/AppData/Local/Temp/wt/w' | Should -BeFalse
        Test-WorktreeStillRegistered -Porcelain $p -Path 'C:/Users/CRISTO~1/AppData/Local/Temp/wt/w' -Branch 'issue-9-x' | Should -BeTrue
    }
    It 'reports a de-registered worktree as gone, whatever is left on disk' {
        Test-WorktreeStillRegistered -Porcelain "worktree C:/repo`nHEAD 1`nbranch refs/heads/main`n" `
            -Path 'C:/wt/issue-9' -Branch 'issue-9-x' | Should -BeFalse
    }
}

Describe 'Resolve-GitPathForm (make our path comparable to git''s, #291)' {
    # Found by a Codex review of #287/#289. Test-WorktreeStillRegistered proves "still there" by
    # NAME: branch first, path second. Both can miss the SAME registered worktree - the branch
    # signal is blind to a DETACHED one, and the path signal is blind when the two strings spell
    # one directory differently. "Could not find it" then read as "gone" and licensed the delete.
    #
    # The strings differ for a real reason, so the cure is to stop them differing at the source.
    # Build a REAL short name rather than assuming %TEMP% carries one: it does on this machine and
    # on the windows-latest runner (RUNNER~1), but that is the runner's business, not a contract.
    # 8.3 generation can also be off per-volume (fsutil 8dot3name), so skip rather than fail there.
    BeforeAll {
        $script:LongDir = Join-Path $TestDrive 'un-nombre-muy-largo-para-forzar-8dot3'
        $script:ShortDir = ''
        if ($IsWindows) {
            New-Item -ItemType Directory -Path $script:LongDir -Force | Out-Null
            try {
                $fso = New-Object -ComObject Scripting.FileSystemObject
                $script:ShortDir = $fso.GetFolder($script:LongDir).ShortPath
            } catch { $script:ShortDir = '' }
        }
    }

    It 'expands an 8.3 short name into the long form git prints' {
        # THE #291 ROOT CAUSE, pinned on a path we shortened ourselves.
        if (-not $script:ShortDir -or $script:ShortDir -notlike '*~*') {
            Set-ItResult -Skipped -Because 'this volume does not generate 8.3 short names'
            return
        }
        $resolved = Resolve-GitPathForm $script:ShortDir
        $resolved | Should -Not -Match '~'
        $resolved | Should -BeLike '*un-nombre-muy-largo-para-forzar-8dot3'
    }
    It 'makes the short and long spellings of one directory match in the registry check' {
        # The end-to-end point of the resolver, at the level the caller cares about. Measured:
        # (Resolve-Path).Path and the FileSystemObject both PRESERVE the short form - only
        # Get-Item/DirectoryInfo expand it - which is why the resolver is written the way it is.
        if (-not $script:ShortDir -or $script:ShortDir -notlike '*~*') {
            Set-ItResult -Skipped -Because 'this volume does not generate 8.3 short names'
            return
        }
        $gitForm = (Get-Item -LiteralPath $script:LongDir).FullName.Replace([char]92, '/')
        $p = "worktree $gitForm`nHEAD 222`ndetached`n"      # detached => the branch signal is blind
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:ShortDir | Should -BeFalse                        # raw: misses it
        Test-WorktreeStillRegistered -Porcelain $p -Path (Resolve-GitPathForm $script:ShortDir) | Should -BeTrue   # resolved: catches it
    }
    It 'returns a non-existent path unchanged instead of throwing' {
        # We cannot expand what is not there - and need not: git cannot hold a LIVE worktree at a
        # path that does not exist, so the raw fallback cannot hide one.
        $gone = Join-Path $env:TEMP 'definitely-not-here-291'
        (Resolve-GitPathForm $gone) | Should -Be $gone
    }
    It 'returns empty for an empty path rather than throwing' {
        (Resolve-GitPathForm '') | Should -Be ''
    }
}

Describe 'Invoke-SessionCleanup (teardown plan, #135)' {
    It 'plans kill -> worktree remove -> branch delete -> registry prune for a pwsh session, under -DryRun' {
        $s = [pscustomobject]@{ issue = 9; branch = 'issue-9-x'; workPath = 'C:\wt\issue-9'; sessionPid = 4321; via = 'pwsh' }
        $acts = @(Invoke-SessionCleanup -Session $s -DryRun)
        $acts.Count | Should -Be 4
        $acts[0] | Should -Match 'kill PID 4321'
        $acts[1] | Should -Match 'worktree remove --force'
        $acts[2] | Should -CMatch 'branch -d issue-9-x'   # safe delete, never -D (#273)
        $acts[3] | Should -Match 'prune #9'
    }
    It 'does NOT kill the wt host PID - instead finds the tab shell by launch script (#413)' {
        $s = [pscustomobject]@{ issue = 8; branch = 'issue-8-w'; workPath = 'C:\wt\issue-8'; sessionPid = 4321; via = 'wt' }
        Mock Find-WtTabShell { return $null }   # no shell running; deterministic
        $acts = @(Invoke-SessionCleanup -Session $s -DryRun)
        ($acts -join ' ') | Should -Not -Match 'kill PID 4321'   # host PID is never killed
        ($acts -join ' ') | Should -Match 'no encontrado'        # tab shell not running
        ($acts -join ' ') | Should -Match 'prune #8'
    }
    It 'kills the pwsh tab shell for a wt session when found by launch script name - #413' {
        $s = [pscustomobject]@{ issue = 8; branch = 'issue-8-w'; workPath = 'C:\wt\issue-8'; sessionPid = 4321; via = 'wt' }
        Mock Find-WtTabShell { return [pscustomobject]@{ ProcessId = 9999; CommandLine = 'pwsh -NoExit -File launch-8.ps1' } }
        $acts = @(Invoke-SessionCleanup -Session $s -DryRun)
        ($acts -join ' ') | Should -Not -Match 'kill PID 4321'   # host PID is never killed
        ($acts -join ' ') | Should -Match 'kill PID 9999'        # kills the actual tab shell
        ($acts -join ' ') | Should -Match 'launch-8'
    }
    It 'skips the PID-kill step when the session has no sessionPid' {
        $s = [pscustomobject]@{ issue = 5; branch = 'issue-5-y'; workPath = 'C:\wt\issue-5'; sessionPid = 0; via = 'pwsh' }
        $acts = @(Invoke-SessionCleanup -Session $s -DryRun)
        ($acts -join ' ') | Should -Not -Match 'kill PID'
        ($acts -join ' ') | Should -Match 'prune #5'
    }

    It 'keeps the branch + registry when the worktree cannot be torn down (Codex #269 fix)' {
        # A real dir that is NOT a git worktree. Since #276 this trips one step earlier - the
        # dirty-check FAILS CLOSED on an unreadable worktree instead of reaching the removal -
        # but the #269 invariant is the same and is what this guards: on ANY failed teardown,
        # never delete the branch and never drop the registry entry.
        $stuck = Join-Path $TestDrive 'stuck-worktree'
        New-Item -ItemType Directory -Path $stuck | Out-Null
        Mock Remove-SessionRegistryEntry { throw 'must not prune on a failed teardown' }
        $s = [pscustomobject]@{ issue = 3; branch = 'issue-3-z'; workPath = $stuck; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s)   # NOT -DryRun
        ($acts -join ' ') | Should -Match 'WARN|FAIL'
        ($acts -join ' ') | Should -Not -Match 'branch -'
        ($acts -join ' ') | Should -Not -Match 'prune #3'
        Should -Invoke Remove-SessionRegistryEntry -Times 0 -Exactly
    }
}

Describe 'Invoke-SessionCleanup asks git, not the disk (#289)' {
    # Real repo + real worktree + a REAL held handle: the whole bug is what the OS and git do to
    # each other here, so a mock would only re-assert my own assumption. The handle stands in for
    # a shell cwd'd inside the worktree, making this the designed case for -Launch sessions.
    BeforeEach {
        $script:Repo2 = Join-Path $TestDrive ('h' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Work2 = "$($script:Repo2)-wt"
        New-Item -ItemType Directory -Path $script:Repo2 | Out-Null
        Push-Location $script:Repo2
        git init -q -b main
        'x' | Set-Content (Join-Path $script:Repo2 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base
        git worktree add -q -b issue-21-h $script:Work2 2>&1 | Out-Null
        Mock Remove-SessionRegistryEntry { }
        # Mock Find-WtTabShell so no real Get-CimInstance is called: the FileStream below is
        # the handle stand-in, not a real pwsh process (#413).
        Mock Find-WtTabShell { return $null }
        # Deny-share handle on a file INSIDE the worktree - what a shell cwd'd in there does.
        $script:Handle = [System.IO.File]::Open((Join-Path $script:Work2 'a.txt'), 'Open', 'Read', 'None')
        function script:New-HSession {
            [pscustomobject]@{ issue = 21; branch = 'issue-21-h'; workPath = $script:Work2; sessionPid = 0; via = 'wt' }
        }
    }
    AfterEach {
        if ($script:Handle) { $script:Handle.Close(); $script:Handle = $null }
        Pop-Location
    }

    It 'finishes the teardown in ONE pass when git released the worktree but the folder lingers' {
        # THE BUG: `remove --force` de-registers the worktree AND fails to delete the directory.
        # Test-Path saw the folder and reported "still present" about something git had let go,
        # so the branch and the registry entry were kept.
        $acts = @(Invoke-SessionCleanup -Session (New-HSession) -PrMerged)
        Test-Path $script:Work2 | Should -BeTrue                      # folder survives: the handle
        ((git worktree list --porcelain) -join "`n") | Should -Not -Match 'issue-21-h'  # git let go
        ($acts -join ' ') | Should -Not -Match 'FAIL'
        ($acts -join ' ') | Should -Match 'NOTA'                      # litter is reported...
        # Parenthesised: Pester binds -Match to the literal '[regex]::Escape' otherwise.
        ($acts -join ' ') | Should -Match ([regex]::Escape($script:Work2))  # ...with its path
        ($acts -join ' ') | Should -Match 'branch -D issue-21-h'
        ($acts -join ' ') | Should -Match 'prune #21'
        (git branch --list 'issue-21-h') | Should -BeNullOrEmpty
        Should -Invoke Remove-SessionRegistryEntry -Times 1 -Exactly
    }

    It 'the OLD Test-Path retry could never converge - the second pass is not a working tree' {
        # Why this mattered more here than in the doctor: workPath comes from the REGISTRY, so a
        # retry re-runs the removal on a path git already forgot. Pin git's real behaviour, which
        # is the whole reason "retry next run" was never going to clean this up.
        git worktree remove --force $script:Work2 2>&1 | Out-Null     # pass 1: de-registers, folder stays
        Test-Path $script:Work2 | Should -BeTrue
        $out = (git worktree remove --force $script:Work2 2>&1) -join ' '   # pass 2, as a later run would
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'not a working tree'
        Test-Path $script:Work2 | Should -BeTrue      # ...so Test-Path stays true FOREVER
    }

    It 'keeps branch + registry when the worktree is still registered but DETACHED (#291)' {
        # The Codex finding, on a real repo. Detached => the branch signal cannot see it; locked
        # => `remove --force` genuinely leaves it registered. Only the resolved path can catch it,
        # and before the fix "I cannot find it" meant "it is gone" -> delete + prune, out from
        # under a live worktree.
        git -C $script:Work2 checkout --detach 2>&1 | Out-Null
        git worktree lock $script:Work2 2>&1 | Out-Null
        try {
            $s = [pscustomobject]@{ issue = 21; branch = 'issue-21-h'; workPath = $script:Work2
                                    sessionPid = 0; via = 'wt' }
            $acts = @(Invoke-SessionCleanup -Session $s -PrMerged)
            ((git worktree list --porcelain) -join "`n") | Should -Match 'detached'   # still registered
            ($acts -join ' ') | Should -Match 'FAIL'
            ($acts -join ' ') | Should -Not -Match 'branch -'
            ($acts -join ' ') | Should -Not -Match 'prune #21'
            Should -Invoke Remove-SessionRegistryEntry -Times 0 -Exactly
        } finally { git worktree unlock $script:Work2 2>&1 | Out-Null }
    }

    It 'CONVERGES on an already-de-registered worktree instead of leaking it forever (#291)' {
        # Codex caught the first cut of this fix re-creating the #289 disease. Proving "some
        # worktree LEFT the list" instead of "MY worktree is not IN it" makes a stale registry
        # entry - one whose worktree git already forgot, e.g. removed by hand - unprovable: the
        # before/after listings are identical, so every retry refused and the entry leaked.
        # workPath here comes from sessions.json, so nothing else would ever clear it.
        $script:Handle.Close(); $script:Handle = $null
        git worktree remove --force $script:Work2 2>&1 | Out-Null     # git already forgot it
        ((git worktree list --porcelain) -join "`n") | Should -Not -Match 'issue-21-h'
        $acts = @(Invoke-SessionCleanup -Session (New-HSession) -PrMerged)
        ($acts -join ' ') | Should -Not -Match 'FAIL'
        ($acts -join ' ') | Should -Match 'prune #21'                  # the entry is finally cleared
        Should -Invoke Remove-SessionRegistryEntry -Times 1 -Exactly
    }

    It 'still keeps branch + registry when git REALLY still registers the worktree' {
        # The guard that must not be lost: a locked worktree survives `remove --force` and stays
        # registered, so the teardown must refuse - branch and tracking both stay.
        git worktree lock $script:Work2 2>&1 | Out-Null
        try {
            $acts = @(Invoke-SessionCleanup -Session (New-HSession) -PrMerged)
            ((git worktree list --porcelain) -join "`n") | Should -Match 'issue-21-h'
            ($acts -join ' ') | Should -Match 'FAIL'
            ($acts -join ' ') | Should -Not -Match 'branch -'
            ($acts -join ' ') | Should -Not -Match 'prune #21'
            (git branch --list 'issue-21-h') | Should -Not -BeNullOrEmpty
            Should -Invoke Remove-SessionRegistryEntry -Times 0 -Exactly
        } finally { git worktree unlock $script:Work2 2>&1 | Out-Null }
    }
}

Describe 'Find-WtTabShellCore (pure: tab shell lookup by launch script - #413)' {
    It 'returns null when no process carries the expected launch script' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 1111; CommandLine = 'pwsh -NoExit -File C:\tmp\launch-42.ps1' }
        )
        $result = Find-WtTabShellCore -Processes $procs -IssueNum 8
        $result | Should -BeNullOrEmpty
    }
    It 'returns the process matching the exact issue number' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 1111; CommandLine = 'pwsh -NoExit -File C:\tmp\launch-42.ps1' }
            [pscustomobject]@{ ProcessId = 2222; CommandLine = 'pwsh -NoExit -File C:\tmp\launch-8.ps1' }
        )
        $result = Find-WtTabShellCore -Processes $procs -IssueNum 8
        $result.ProcessId | Should -Be 2222
    }
    It 'does NOT match a different issue that shares digits (e.g. issue 8 vs 82)' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 3333; CommandLine = 'pwsh -NoExit -File C:\tmp\launch-82.ps1' }
        )
        $result = Find-WtTabShellCore -Processes $procs -IssueNum 8
        $result | Should -BeNullOrEmpty
    }
    It 'returns null for an empty process list' {
        $result = Find-WtTabShellCore -Processes @() -IssueNum 42
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SessionCleanup does not discard a dirty worktree (#276)' {
    # Real repo + real linked worktree: `git worktree remove --force` only destroys real
    # uncommitted work, so nothing short of the real thing tests this.
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ('w' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Work = "$($script:Repo)-wt"
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        Push-Location $script:Repo
        git init -q -b main
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
        git worktree add -q -b issue-20-wt $script:Work 2>&1 | Out-Null
        Mock Remove-SessionRegistryEntry { }
        function script:New-Session {
            [pscustomobject]@{ issue = 20; branch = 'issue-20-wt'; workPath = $script:Work; sessionPid = 0 }
        }
    }
    AfterEach { Pop-Location }

    It 'REFUSES to remove a DIRTY worktree on an unmerged session, and says so' {
        'work in progress' | Set-Content (Join-Path $script:Work 'scratch.txt')   # untracked
        $acts = @(Invoke-SessionCleanup -Session (New-Session))
        ($acts -join ' ') | Should -Match 'WARN'
        ($acts -join ' ') | Should -Match 'scratch|sin commitear|worktree'
        ($acts -join ' ') | Should -Match '#20'
        Test-Path (Join-Path $script:Work 'scratch.txt') | Should -BeTrue   # the work survives
    }

    It 'keeps the branch AND the registry entry when it refuses (leftover stays tracked)' {
        'work in progress' | Set-Content (Join-Path $script:Work 'scratch.txt')
        $acts = @(Invoke-SessionCleanup -Session (New-Session))
        ($acts -join ' ') | Should -Not -Match 'branch -'
        ($acts -join ' ') | Should -Not -Match 'prune #20'
        Should -Invoke Remove-SessionRegistryEntry -Times 0 -Exactly
        (git branch --list 'issue-20-wt') | Should -Not -BeNullOrEmpty
    }

    It 'a modified TRACKED file counts as dirty too (not just untracked)' {
        git -C $script:Work checkout -q main 2>&1 | Out-Null
        'tracked' | Set-Content (Join-Path $script:Work 'f.txt')
        git -C $script:Work add f.txt
        git -C $script:Work -c user.email=t@t -c user.name=t commit -q -m add
        'modified after the commit' | Set-Content (Join-Path $script:Work 'f.txt')
        $acts = @(Invoke-SessionCleanup -Session (New-Session))
        ($acts -join ' ') | Should -Match 'WARN'
        Test-Path $script:Work | Should -BeTrue
    }

    It 'REGRESSION: still removes a CLEAN worktree exactly as before (happy path intact)' {
        $acts = @(Invoke-SessionCleanup -Session (New-Session))
        ($acts -join ' ') | Should -Not -Match 'WARN'
        ($acts -join ' ') | Should -Match 'worktree remove --force'
        ($acts -join ' ') | Should -Match 'prune #20'
        Test-Path $script:Work | Should -BeFalse
    }

    It 'removes a DIRTY worktree when the PR merged (the work landed - nothing to save)' {
        'leftover' | Set-Content (Join-Path $script:Work 'scratch.txt')
        $acts = @(Invoke-SessionCleanup -Session (New-Session) -PrMerged)
        ($acts -join ' ') | Should -Not -Match 'WARN'
        Test-Path $script:Work | Should -BeFalse
    }

    It '-ForceRemoveWorktree discards a dirty worktree on purpose (opt-in escape hatch)' {
        'leftover' | Set-Content (Join-Path $script:Work 'scratch.txt')
        $acts = @(Invoke-SessionCleanup -Session (New-Session) -ForceRemoveWorktree)
        ($acts -join ' ') | Should -Not -Match 'WARN'
        Test-Path $script:Work | Should -BeFalse
    }

    It 'FAILS CLOSED when the worktree cannot be inspected (no output != clean)' {
        # Break the link so `git status` errors: empty output must not read as "clean" and
        # hand the --force the one case we cannot vouch for (Codex #277).
        Remove-Item (Join-Path $script:Work '.git') -Force
        $acts = @(Invoke-SessionCleanup -Session (New-Session))
        # Assert the EXIT-CODE branch specifically. Matching a bare 'WARN' would pass even
        # without the guard, because 2>&1 puts git's error text in the output and that alone
        # reads as "dirty" - an accident, not the guard. Pin the message so it stays honest.
        ($acts -join ' ') | Should -Match 'no pude comprobar'
        ($acts -join ' ') | Should -Not -Match 'prune #20'
        Test-Path $script:Work | Should -BeTrue
        Should -Invoke Remove-SessionRegistryEntry -Times 0 -Exactly
    }
}

Describe 'Invoke-SessionCleanup branch deletion is merge-safe (#273)' {
    # A real throwaway repo: `git branch -d` only refuses for real against real history.
    # No workPath on the session -> the worktree step is skipped and the branch step runs.
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ('r' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        Push-Location $script:Repo
        git init -q -b main
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
        Mock Remove-SessionRegistryEntry { }
        # A branch carrying a commit main does not have -> `git branch -d` refuses it.
        # Defined here, not in the Describe body: that body runs at DISCOVERY, so a
        # function declared there is gone by the time the It blocks run (Pester v5).
        function script:New-UnmergedBranch {
            param([string]$Name)
            git checkout -q -b $Name
            git -c user.email=t@t -c user.name=t commit -q --allow-empty -m unmerged
            git checkout -q main
        }
    }
    AfterEach { Pop-Location }

    It 'keeps an UNMERGED branch and WARNs naming the branch + issue' {
        New-UnmergedBranch -Name 'issue-7-unmerged'
        $s = [pscustomobject]@{ issue = 7; branch = 'issue-7-unmerged'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s)   # NOT -DryRun
        ($acts -join ' ') | Should -Match 'WARN'
        ($acts -join ' ') | Should -Match 'issue-7-unmerged'
        ($acts -join ' ') | Should -Match '#7'
        # The commits survive: the branch is still there for the audit path.
        (git branch --list 'issue-7-unmerged') | Should -Not -BeNullOrEmpty
    }

    It 'deletes a MERGED branch quietly (no WARN)' {
        git branch issue-8-merged           # points at main -> merged by definition
        $s = [pscustomobject]@{ issue = 8; branch = 'issue-8-merged'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s)
        ($acts -join ' ') | Should -Not -Match 'WARN'
        (git branch --list 'issue-8-merged') | Should -BeNullOrEmpty
    }

    It 'still prunes the registry entry when the branch is kept (the worktree IS gone)' {
        New-UnmergedBranch -Name 'issue-9-unmerged'
        $s = [pscustomobject]@{ issue = 9; branch = 'issue-9-unmerged'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s)
        (git branch --list 'issue-9-unmerged') | Should -Not -BeNullOrEmpty   # kept...
        ($acts -join ' ') | Should -Match 'prune #9'                          # ...yet still pruned
        Should -Invoke Remove-SessionRegistryEntry -Times 1 -Exactly
    }

    It 'does NOT cry wolf about a branch that is already gone' {
        $s = [pscustomobject]@{ issue = 12; branch = 'issue-12-never-existed'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s)
        ($acts -join ' ') | Should -Not -Match 'WARN'
        ($acts -join ' ') | Should -Match 'prune #12'
    }

    It 'REGRESSION: -PrMerged deletes a SQUASH-merged branch (never an ancestor of main)' {
        # The flow squash-merges by default, which rewrites the commits: the branch tip is
        # NOT an ancestor of main, so `-d` refuses even though the PR landed perfectly.
        # Without the -PrMerged licence every successful session would leak a branch + WARN.
        git checkout -q -b issue-11-squashed
        'work' | Set-Content (Join-Path $script:Repo 'f.txt')
        git add f.txt
        git -c user.email=t@t -c user.name=t commit -q -m work
        git checkout -q main
        git merge --squash issue-11-squashed 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m 'squashed (#11)'
        # Precondition: the safe delete really would refuse this branch.
        git branch -d issue-11-squashed 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        $s = [pscustomobject]@{ issue = 11; branch = 'issue-11-squashed'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s -PrMerged)
        ($acts -join ' ') | Should -Not -Match 'WARN'
        (git branch --list 'issue-11-squashed') | Should -BeNullOrEmpty
    }

    It '-ForceDeleteBranch discards an unmerged branch on purpose (opt-in escape hatch)' {
        New-UnmergedBranch -Name 'issue-10-unmerged'
        $s = [pscustomobject]@{ issue = 10; branch = 'issue-10-unmerged'; workPath = $null; sessionPid = 0 }
        $acts = @(Invoke-SessionCleanup -Session $s -ForceDeleteBranch)
        ($acts -join ' ') | Should -CMatch 'branch -D issue-10-unmerged'
        ($acts -join ' ') | Should -Not -Match 'WARN'
        (git branch --list 'issue-10-unmerged') | Should -BeNullOrEmpty
    }
}

Describe 'Remove-SessionRegistryEntry (prune one issue, #135)' {
    It 'removes only the named issue and keeps the rest' {
        $tmp = Join-Path $TestDrive 'sessions.json'
        @(
            [pscustomobject]@{ issue = 1; branch = 'a' },
            [pscustomobject]@{ issue = 2; branch = 'b' }
        ) | ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
        Mock Get-SessionRegistryPath { $tmp }
        Remove-SessionRegistryEntry -IssueNum 1
        $after = @(Get-Content $tmp -Raw | ConvertFrom-Json)
        $after.Count | Should -Be 1
        [int]$after[0].issue | Should -Be 2
    }
    It 'is a no-op when the registry file is absent' {
        Mock Get-SessionRegistryPath { Join-Path $TestDrive 'missing.json' }
        { Remove-SessionRegistryEntry -IssueNum 1 } | Should -Not -Throw
    }
}

Describe 'Read-SessionRegistry (read-only view, does NOT rewrite the file - Codex #269)' {
    It 'filters dead PIDs from the RETURN but leaves the file untouched' {
        $tmp = Join-Path $TestDrive 'ro-sessions.json'
        @(
            [pscustomobject]@{ issue = 4; sessionPid = 999999 },   # dead
            [pscustomobject]@{ issue = 5; sessionPid = $PID }       # live (this test process)
        ) | ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
        Mock Get-SessionRegistryPath { $tmp }
        $live = @(Read-SessionRegistry)
        $live.Count | Should -Be 1
        [int]$live[0].issue | Should -Be 5
        # The dead entry must STILL be on disk (not silently pruned) so -Watch/-AutoClean
        # can see it, classify it done, and tear down its worktree.
        $onDisk = @(Get-Content $tmp -Raw | ConvertFrom-Json)
        $onDisk.Count | Should -Be 2
    }
}

Describe 'Write-SessionRegistryEntry preserves other issues (Codex #269)' {
    It 'keeps a different issue''s dead-PID session when writing a new one' {
        $tmp = Join-Path $TestDrive 'w-sessions.json'
        @([pscustomobject]@{ issue = 100; branch = 'issue-100-a'; workPath = 'C:\wt\100'; sessionPid = 999999 }) |
            ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
        Mock Get-SessionRegistryPath { $tmp }
        # Explicit alive SessionPid ($PID) avoids the CIM parent-PID lookup.
        Write-SessionRegistryEntry -IssueNum 200 -Branch 'issue-200-b' -WorkPath 'C:\wt\200' -Repo 'o/r' -SessionPid $PID
        $onDisk = @(Get-Content $tmp -Raw | ConvertFrom-Json)
        ($onDisk | Where-Object { $_.issue -eq 100 }).Count | Should -Be 1   # dead entry preserved for -Watch
        ($onDisk | Where-Object { $_.issue -eq 200 }).Count | Should -Be 1   # new entry written
    }
}

Describe 'Read-SessionRegistryRaw (no dead-PID pruning, #135 / Codex #269)' {
    It 'returns entries verbatim WITHOUT pruning a dead PID (so the watcher can classify it done)' {
        $tmp = Join-Path $TestDrive 'raw-sessions.json'
        # PID 999999 is not a live process -> the live reader would prune it; raw keeps it.
        @([pscustomobject]@{ issue = 8; branch = 'issue-8-x'; sessionPid = 999999 }) |
            ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
        Mock Get-SessionRegistryPath { $tmp }
        $raw = @(Read-SessionRegistryRaw)
        $raw.Count | Should -Be 1
        [int]$raw[0].issue | Should -Be 8
    }
    It 'returns an empty array when the registry is absent' {
        Mock Get-SessionRegistryPath { Join-Path $TestDrive 'nope.json' }
        @(Read-SessionRegistryRaw).Count | Should -Be 0
    }
}

Describe 'Invoke-SessionWatch (DI poll loop, #135)' {
    It 'returns allDone when every session is finished on the first poll' {
        $r = Invoke-SessionWatch `
            -ReadSessions { @([pscustomobject]@{ issue = 1 }, [pscustomobject]@{ issue = 2 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'PR merged' } } `
            -Now { Get-Date } -Sleep { param($sec) }
        $r.allDone  | Should -BeTrue
        $r.timedOut | Should -BeFalse
    }
    It 'returns allDone when the registry is empty' {
        $r = Invoke-SessionWatch -ReadSessions { @() } -Now { Get-Date } -Sleep { param($sec) }
        $r.allDone | Should -BeTrue
    }
    It 'times out when a session stays in progress' {
        $script:t = 0
        $r = Invoke-SessionWatch -TimeoutSec 5 `
            -ReadSessions { @([pscustomobject]@{ issue = 1 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $false; reason = 'en progreso' } } `
            -Now  { $script:t += 10; [datetime]::new(2026,1,1,0,0,0).AddSeconds($script:t) } `
            -Sleep { param($sec) }
        $r.timedOut | Should -BeTrue
        $r.allDone  | Should -BeFalse
    }
    It 'runs the supervisor every -SuperviseEvery cycles so stalls get posted without a human command (#565)' {
        $script:t2 = 0
        $script:supervised = 0
        Invoke-SessionWatch -TimeoutSec 100 -SuperviseEvery 2 `
            -ReadSessions { @([pscustomobject]@{ issue = 1 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $false; reason = 'en progreso' } } `
            -Now  { $script:t2 += 10; [datetime]::new(2026,1,1,0,0,0).AddSeconds($script:t2) } `
            -Sleep { param($sec) } `
            -Supervise { $script:supervised++ } | Out-Null
        # 10 polls before the 100s timeout, one supervision every 2 -> at least 3 calls.
        $script:supervised | Should -BeGreaterThan 2
    }
    It 'SuperviseEvery 0 disables supervision entirely' {
        $script:t3 = 0
        $script:supervised2 = 0
        Invoke-SessionWatch -TimeoutSec 50 -SuperviseEvery 0 `
            -ReadSessions { @([pscustomobject]@{ issue = 1 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $false; reason = 'en progreso' } } `
            -Now  { $script:t3 += 10; [datetime]::new(2026,1,1,0,0,0).AddSeconds($script:t3) } `
            -Sleep { param($sec) } `
            -Supervise { $script:supervised2++ } | Out-Null
        $script:supervised2 | Should -Be 0
    }
    It 'auto-cleans each finished session exactly once' {
        Mock Invoke-SessionCleanup { @('mock teardown') }
        $r = Invoke-SessionWatch -AutoClean `
            -ReadSessions { @([pscustomobject]@{ issue = 7 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'issue cerrado' } } `
            -Now { Get-Date } -Sleep { param($sec) }
        Should -Invoke Invoke-SessionCleanup -Times 1 -Exactly
        $r.cleaned | Should -Contain 7
    }
    It 'carries the merged verdict into the teardown (licenses the force-delete, #273)' {
        $script:seen = $null
        Mock Invoke-SessionCleanup { $script:seen = $PrMerged; @('mock teardown') }
        Invoke-SessionWatch -AutoClean `
            -ReadSessions { @([pscustomobject]@{ issue = 7 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'PR merged'; merged = $true } } `
            -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        $script:seen | Should -BeTrue
    }
    It 'forwards -ForceRemoveWorktree to the teardown (#276)' {
        $script:seenForce = $null
        Mock Invoke-SessionCleanup { $script:seenForce = $ForceRemoveWorktree; @('mock teardown') }
        Invoke-SessionWatch -AutoClean -ForceRemoveWorktree `
            -ReadSessions { @([pscustomobject]@{ issue = 7 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'x'; merged = $false } } `
            -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        $script:seenForce | Should -BeTrue
    }
    It 'does NOT license the force-delete for a session that finished unmerged (#273)' {
        $script:seen = $null
        Mock Invoke-SessionCleanup { $script:seen = $PrMerged; @('mock teardown') }
        Invoke-SessionWatch -AutoClean `
            -ReadSessions { @([pscustomobject]@{ issue = 7 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'proceso terminado'; merged = $false } } `
            -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        $script:seen | Should -BeFalse
    }
    It 'does NOT clean when -AutoClean is off' {
        Mock Invoke-SessionCleanup { @('should not run') }
        Invoke-SessionWatch `
            -ReadSessions { @([pscustomobject]@{ issue = 7 }) } `
            -GetStatus    { param($s) [pscustomobject]@{ done = $true; reason = 'x' } } `
            -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        Should -Invoke Invoke-SessionCleanup -Times 0 -Exactly
    }
}

Describe 'Test-Pending (vocabulary-aware pending detection, issue #278)' {
    It 'counts a canonical Backlog item as pending' {
        Test-Pending ([pscustomobject]@{ status = 'Backlog' }) | Should -BeTrue
    }
    It 'counts an item with no Status as pending' {
        Test-Pending ([pscustomobject]@{ status = $null }) | Should -BeTrue
        Test-Pending ([pscustomobject]@{ status = ''    }) | Should -BeTrue
    }
    It "counts a default-template 'Todo' item as pending (the #278 false negative)" {
        Test-Pending ([pscustomobject]@{ status = 'Todo' })  | Should -BeTrue
        Test-Pending ([pscustomobject]@{ status = 'To Do' }) | Should -BeTrue
    }
    It 'does NOT count work already moving or finished' {
        Test-Pending ([pscustomobject]@{ status = 'In Progress' }) | Should -BeFalse
        Test-Pending ([pscustomobject]@{ status = 'In Review' })   | Should -BeFalse
        Test-Pending ([pscustomobject]@{ status = 'Done' })        | Should -BeFalse
    }
    It 'does not guess: an unknown Status is not pending' {
        Test-Pending ([pscustomobject]@{ status = 'Pendiente' }) | Should -BeFalse
    }
}

Describe 'Get-LegacyStatusOptions (schema warning, issue #278)' {
    It "flags a default-template board's legacy Todo option" {
        Get-LegacyStatusOptions @('Todo', 'In Progress', 'Done') | Should -Be @('Todo')
    }
    It 'flags nothing on a canonical board' {
        @(Get-LegacyStatusOptions @('Backlog', 'In Progress', 'In Review', 'Blocked', 'Done')).Count | Should -Be 0
    }
    It "does not flag a vocabulary it cannot read - that is the user's own, not a legacy name" {
        @(Get-LegacyStatusOptions @('Pendiente', 'Icebox')).Count | Should -Be 0
    }
    It 'handles a board with no Status options at all' {
        @(Get-LegacyStatusOptions @()).Count | Should -Be 0
    }
}

Describe 'Get-UnknownStatusValues (never claim a clean board blindly, issue #278)' {
    It 'reports the distinct statuses that map to no canonical option' {
        $items = @(
            [pscustomobject]@{ status = 'Pendiente' }
            [pscustomobject]@{ status = 'Pendiente' }
            [pscustomobject]@{ status = 'Icebox' }
            [pscustomobject]@{ status = 'Done' }
        )
        Get-UnknownStatusValues $items | Should -Be @('Pendiente', 'Icebox')
    }
    It 'reports nothing when every status is understood (canonical or legacy)' {
        $items = @(
            [pscustomobject]@{ status = 'Todo' }
            [pscustomobject]@{ status = 'In Progress' }
            [pscustomobject]@{ status = $null }
        )
        @(Get-UnknownStatusValues $items).Count | Should -Be 0
    }
    It 'reports nothing for an empty board' {
        @(Get-UnknownStatusValues @()).Count | Should -Be 0
    }
}

Describe 'Resolve-StatusOptionId (every Status WRITE is vocabulary-aware, PR #279)' {
    BeforeAll {
        $script:CanonNode = [pscustomobject]@{ options = @(
            [pscustomobject]@{ id = 'c1'; name = 'Backlog' }
            [pscustomobject]@{ id = 'c2'; name = 'In Review' }
        ) }
        $script:LegacyNode = [pscustomobject]@{ options = @(
            [pscustomobject]@{ id = 'l1'; name = 'Todo' }
            [pscustomobject]@{ id = 'l2'; name = 'Review' }
        ) }
    }
    It 'resolves the canonical option on a canonical board' {
        Resolve-StatusOptionId $script:CanonNode 'Backlog'   | Should -Be 'c1'
        Resolve-StatusOptionId $script:CanonNode 'In Review' | Should -Be 'c2'
    }
    It "resolves -Unlock's Backlog target to a legacy board's 'Todo' (was silently null)" {
        Resolve-StatusOptionId $script:LegacyNode 'Backlog' | Should -Be 'l1'
    }
    It "resolves -ToReview to a board that calls the column 'Review'" {
        Resolve-StatusOptionId $script:LegacyNode 'In Review' | Should -Be 'l2'
    }
    It 'returns $null when no name matches, so the caller can refuse loudly' {
        Resolve-StatusOptionId $script:LegacyNode 'Blocked' | Should -BeNullOrEmpty
        Resolve-StatusOptionId $null 'Backlog'              | Should -BeNullOrEmpty
    }
}

Describe 'Get-CloseLoopDisposition (cerrar-ciclo router #302)' {
    It 'on the default branch -> nothing to close' {
        (Get-CloseLoopDisposition -OnDefault $true).State | Should -Be 'on-default'
        (Get-CloseLoopDisposition -OnDefault $true).CanCleanup | Should -BeFalse
    }
    It 'uncommitted work is decided BEFORE any PR state (never lose it to cleanup)' {
        $merged = [pscustomobject]@{ number = 9; state = 'MERGED'; merged = $true }
        $d = Get-CloseLoopDisposition -OnDefault $false -Dirty 'dirty' -Pr $merged
        $d.State | Should -Be 'dirty'
        $d.CanCleanup | Should -BeFalse
    }
    It 'an unreadable working tree (unknown) fails closed as dirty' {
        (Get-CloseLoopDisposition -OnDefault $false -Dirty 'unknown').State | Should -Be 'dirty'
    }
    It 'a proven-merged branch (tip == PR head) is the only CanCleanup state' {
        $pr = [pscustomobject]@{ number = 42; state = 'MERGED'; merged = $true }
        $d = Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -Pr $pr
        $d.State | Should -Be 'merged'
        $d.CanCleanup | Should -BeTrue
        $d.Summary | Should -Match '#42'
    }
    It 'a MERGED PR whose head is NOT our tip is merged-advanced, never deletable' {
        $pr = [pscustomobject]@{ number = 42; state = 'MERGED'; merged = $false }
        $d = Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -Pr $pr
        $d.State | Should -Be 'merged-advanced'
        $d.CanCleanup | Should -BeFalse
    }
    It 'an OPEN PR routes to the review gate' {
        $pr = [pscustomobject]@{ number = 7; state = 'OPEN'; merged = $false }
        $d = Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -Pr $pr
        $d.State | Should -Be 'in-review'
        $d.Hint  | Should -Match 'Board-ReviewGate.*7'
    }
    It 'a CLOSED-unmerged PR routes to a rescue/discard decision' {
        $pr = [pscustomobject]@{ number = 7; state = 'CLOSED'; merged = $false }
        (Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -Pr $pr).State | Should -Be 'closed-unmerged'
    }
    It 'commits but no PR routes to opening one' {
        $d = Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -CommitsAhead 3 -Pr $null
        $d.State | Should -Be 'no-pr'
        $d.Hint  | Should -Match 'New-BoardPR'
    }
    It 'a fresh work branch with no commits and no PR has nothing to close' {
        (Get-CloseLoopDisposition -OnDefault $false -Dirty 'clean' -CommitsAhead 0 -Pr $null).State | Should -Be 'empty'
    }
}
