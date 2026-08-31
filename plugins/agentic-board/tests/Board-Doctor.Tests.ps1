#Requires -Modules Pester
<#  Pester tests for Board-Doctor.ps1 - the git-reality branch/worktree audit (#274).

    The whole point of the command is that it does NOT trust `git branch --merged` (this repo
    squash-merges, so a merged branch is never an ancestor of main - the #273 trap, PR #275)
    and does NOT trust `sessions.json` (a process registry, not a ref inventory). So the tests
    pin exactly that: the merge verdict comes from the PR state AND the head OID matching the
    local tip, and the registry can only ever protect a branch, never define one.

    Everything under test is pure: the classifier takes every fact as an argument, so no git,
    no gh and no token are needed.

    The syntax check that used to live here (the "limite de $PrLimit:" trap that broke every run)
    now covers every script in the plugin, in Scripts.Parse.Tests.ps1 (#282). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Doctor.ps1' | Resolve-Path
    # The doctor dot-sources Board-Work.ps1 for Get-SessionCompletion; both guards must be set
    # so neither script runs its main entry (or demands a token).
    $env:ABIOS_DOCTOR_DOTSOURCE   = '1'
    . $script:Script
    $env:ABIOS_DOCTOR_DOTSOURCE   = ''

    $script:Now = [datetime]'2026-07-15T12:00:00'
    $script:Tip = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $script:Other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

    function New-Pr {
        param([int]$Number = 1, [string]$State = 'MERGED', [string]$HeadRefOid = $script:Tip)
        [pscustomobject]@{ number = $Number; state = $State; headRefOid = $HeadRefOid }
    }
    # A branch classified with sensible defaults; every test overrides only what it is about.
    function Invoke-Classify {
        param([hashtable]$With = @{})
        $args = @{
            Name = 'issue-9-thing'; Tip = $script:Tip; Prs = @()
            CommitDate = $script:Now.AddDays(-1); Now = $script:Now; StaleDays = 30
        }
        foreach ($k in $With.Keys) { $args[$k] = $With[$k] }
        Get-BranchClass @args
    }
}

Describe 'Board-Doctor dot-source contract' {
    It 'reuses Get-SessionCompletion from Board-Work instead of re-implementing the merge verdict' {
        # If this ever fails, someone copied the verdict into the doctor and the two can drift.
        Get-Command Get-SessionCompletion -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'defines its pure helpers without touching git, gh or the token' {
        Get-Command Get-BranchClass     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-WorktreeRecords -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Select-BranchPr     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Board-Doctor parameter binding survives the dot-source' {
    # Regression: dot-sourcing Board-Work.ps1 runs ITS param() block in our scope, which reset
    # every shared parameter name to Board-Work's default. -DryRun became $false, so
    # `-Fix -DryRun` printed "DRY-RUN" and then really deleted branches. Caught by running it.
    It 'shares parameter names with Board-Work, so the clobbering risk is real and must stay covered' {
        $doctor = (Get-Command $script:Script).Parameters.Keys
        $work   = (Get-Command (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path)).Parameters.Keys
        $shared = @($doctor | Where-Object { $work -contains $_ -and $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
        # If this ever drops to zero the restore is dead code and can go; today it is not.
        $shared | Should -Contain 'DryRun'
        $shared | Should -Contain 'Repo'
    }
    It 'replays $PSBoundParameters after the dot-source so the caller binding wins' {
        # Source-level, on purpose: the fix is top-level script code (not a function), and the
        # end-to-end proof needs a real repo + gh, which the rest of this suite deliberately
        # never touches. Verified by hand against the live repo: `-Fix -DryRun` over 57
        # merged branches left 62/62 branches intact.
        $src = Get-Content $script:Script -Raw
        $src | Should -Match 'foreach \(\$k in \$PSBoundParameters\.Keys\)'
        # The replay must sit in the `finally` of the dot-source, i.e. BEFORE anything reads
        # $DryRun/$Fix. If someone moves it below the first use, the guard is decorative.
        $replayAt = $src.IndexOf('$PSBoundParameters.Keys')
        $firstUse = $src.IndexOf('if ($DryRun)')
        $replayAt | Should -BeGreaterThan 0
        $replayAt | Should -BeLessThan $firstUse
    }
    It 'fails closed on every source it cannot vouch for' {
        # No PRs must never read as "nothing is merged" (that would reclassify every merged
        # branch as stale and offer 57 to -Fix); an empty branch/worktree inventory must never
        # read as "nothing to clean"; and an unreadable registry must never read as "no live
        # sessions" (that would strip a live branch of its veto). Raised by the Codex review
        # of PR #280 - each of these failed OPEN before.
        $src = Get-Content $script:Script -Raw
        $src | Should -Match 'if \(\$LASTEXITCODE -ne 0 -or \$null -eq \$prJson\)'   # gh pr list
        $src | Should -Match "'git for-each-ref' fallo"                              # branch inventory
        $src | Should -Match "'git worktree list' fallo"                             # worktree inventory
        $src | Should -Match 'if \(-not \$registryTrusted\)'                         # registry veto
    }
}

Describe 'Get-WorktreeRecords (porcelain parsing)' {
    It 'parses a normal worktree record' {
        $r = Get-WorktreeRecords -Porcelain "worktree C:/repo`nHEAD abc`nbranch refs/heads/issue-1-x`n"
        $r.Count       | Should -Be 1
        $r[0].Path     | Should -Be 'C:/repo'
        $r[0].Branch   | Should -Be 'issue-1-x'
        $r[0].Prunable | Should -BeNullOrEmpty
    }
    It 'parses several blank-line separated records' {
        $p = "worktree C:/a`nHEAD 111`nbranch refs/heads/one`n`nworktree C:/b`nHEAD 222`nbranch refs/heads/two`n"
        $r = Get-WorktreeRecords -Porcelain $p
        $r.Count      | Should -Be 2
        $r[1].Branch  | Should -Be 'two'
    }
    It 'captures the prunable reason git reports for a ghost worktree' {
        # This is the "worktree path gone" case - taken from git, never guessed.
        $r = Get-WorktreeRecords -Porcelain "worktree C:/gone`nHEAD abc`nbranch refs/heads/dead`nprunable gitdir file points to non-existent location`n"
        $r[0].Prunable | Should -Be 'gitdir file points to non-existent location'
    }
    It 'handles a detached and a bare worktree without inventing a branch' {
        $r = Get-WorktreeRecords -Porcelain "worktree C:/d`nHEAD abc`ndetached`n`nworktree C:/bare`nbare`n"
        $r[0].Detached | Should -BeTrue
        $r[0].Branch   | Should -BeNullOrEmpty
        $r[1].Bare     | Should -BeTrue
    }
    It 'returns nothing for empty input rather than throwing' {
        (Get-WorktreeRecords -Porcelain '').Count | Should -Be 0
    }
    It 'tolerates CRLF line endings' {
        $r = Get-WorktreeRecords -Porcelain "worktree C:/a`r`nHEAD 111`r`nbranch refs/heads/one`r`n"
        $r[0].Branch | Should -Be 'one'
    }
}

Describe 'Test-WorktreeStillRegistered (did the remove take, per git)' {
    # Regression (#287): the post-remove check used to ask the FILESYSTEM. On the 58-branch
    # cleanup `git worktree remove --force` de-registered the worktree correctly, but the
    # directory survived - empty, held by an open handle from the session that made it. Test-Path
    # said "still there", so the doctor printed "el worktree sigue presente" and kept a merged
    # branch that a second -Fix pass then deleted. The authority is git's registry, not the disk.
    # ONE BeforeAll: Pester keeps only the last one per block, so a second would silently blank
    # these out and leave the path assertions passing against $null.
    BeforeAll {
        $script:Br = 'issue-282-parse-all-scripts'
        $script:Wt = "C:/Users/x/Repos/r--worktrees/$script:Br"
    }

    It 'says YES while git still lists a worktree holding the branch' {
        $p = "worktree C:/repo`nHEAD 111`nbranch refs/heads/main`n`nworktree $($script:Wt)`nHEAD 222`nbranch refs/heads/$($script:Br)`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:Wt -Branch $script:Br | Should -BeTrue
    }
    It 'says NO once git has dropped it, even though the folder may linger on disk' {
        # THE BUG (#287): this is the case that used to read as "FAIL, still present".
        $p = "worktree C:/repo`nHEAD 111`nbranch refs/heads/main`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:Wt -Branch $script:Br | Should -BeFalse
    }
    It 'blocks on the branch even when the two path strings do not compare equal' {
        # THE FAIL-OPEN this helper exists to avoid, and it is not hypothetical: caught on a real
        # locked worktree while testing this fix. git prints the LONG path; a path routed through
        # %TEMP% carries the 8.3 short name, so the strings differ for the same directory. Path
        # equality alone answers "not registered" and licenses deleting a branch git still holds.
        $p = "worktree C:/Users/Cristobal/AppData/Local/Temp/wt/wt-locked`nHEAD 222`nbranch refs/heads/$($script:Br)`n"
        $short = 'C:/Users/CRISTO~1/AppData/Local/Temp/wt/wt-locked'
        Test-WorktreeStillRegistered -Porcelain $p -Path $short                        | Should -BeFalse  # path alone: fools it
        Test-WorktreeStillRegistered -Porcelain $p -Path $short -Branch $script:Br     | Should -BeTrue   # branch: catches it
    }
    It 'still blocks on the path alone, for a detached worktree with no branch to match' {
        $p = "worktree $($script:Wt)`nHEAD 222`ndetached`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:Wt -Branch $script:Br | Should -BeTrue
    }
    It 'matches a path regardless of separator style and trailing slash' {
        # git's porcelain emits forward slashes; our path may have been round-tripped through
        # Resolve-Path, which emits backslashes. Verified against real `git worktree list` output.
        $p = "worktree $($script:Wt)`nHEAD 222`ndetached`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path ($script:Wt -replace '/', '\')  | Should -BeTrue
        Test-WorktreeStillRegistered -Porcelain $p -Path ($script:Wt + '/')              | Should -BeTrue
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:Wt.ToUpper()            | Should -BeTrue
    }
    It 'does not confuse a sibling worktree whose path merely starts the same' {
        # `...-parse-all-scripts` must not be answered by `...-parse-all-scripts-2`.
        $p = "worktree $($script:Wt)-2`nHEAD 222`ndetached`n"
        Test-WorktreeStillRegistered -Porcelain $p -Path $script:Wt | Should -BeFalse
    }
    It 'does not confuse a branch whose name merely starts the same' {
        $p = "worktree C:/other`nHEAD 222`nbranch refs/heads/$($script:Br)-2`n"
        Test-WorktreeStillRegistered -Porcelain $p -Branch $script:Br | Should -BeFalse
    }
    It 'reads an empty registry as "not registered" rather than throwing' {
        Test-WorktreeStillRegistered -Porcelain '' -Path $script:Wt -Branch $script:Br | Should -BeFalse
    }
}

Describe 'Remove-BranchAndWorktree asks git, not the disk (#287)' {
    # The helper itself runs git, so it is not unit-testable without a repo. Pin the CONTRACT at
    # the source level instead: the decision must go through git's registry, and the Test-Path
    # that caused the two-pass cleanup must not creep back in as the gate.
    # Asserted with -BeTrue over a match rather than `$Src | Should -Match`, whose failure
    # message pastes the entire 600-line script into the output.
    BeforeAll {
        $script:Src = Get-Content $script:Script -Raw
        $fn = $script:Src.Substring($script:Src.IndexOf('function Remove-BranchAndWorktree'))
        $script:RemoveFn = $fn.Substring(0, $fn.IndexOf("`n}"))
    }

    It 'gates the branch delete on the porcelain registry' {
        ($script:RemoveFn -match 'Test-WorktreeStillRegistered') | Should -BeTrue
    }
    It 'passes the BRANCH to the gate, not only the path' {
        # Path-only is the fail-open case (see the 8.3 short-name test above): the branch is the
        # signal that actually decides whether `git branch -D` can succeed.
        ($script:RemoveFn -match '-Branch \$Row\.Branch') | Should -BeTrue
    }
    It 'resolves the path BEFORE the remove, while there is still a directory to resolve (#291)' {
        # A detached worktree is invisible to the branch signal, so the path is the only signal
        # left - and it only works once both sides spell the directory the same way. Resolving
        # after the removal would be too late: the directory may be gone.
        $res = $script:RemoveFn.IndexOf('Resolve-GitPathForm')
        $rm  = $script:RemoveFn.IndexOf('git worktree remove --force $Row.WorktreePath 2>&1')
        $res | Should -BeGreaterThan 0
        $res | Should -BeLessThan $rm
    }
    It 'never lets Test-Path of the worktree path veto the delete again' {
        # Test-Path may still REPORT a leftover folder - that note is useful. What must never come
        # back is the folder VETOING the branch delete, i.e. a Test-Path whose body bails out.
        # If it does, the 58-branch cleanup needs two passes again.
        ($script:RemoveFn -match '(?s)Test-Path \$Row\.WorktreePath.{0,400}?return') | Should -BeFalse
    }
    It 'checks the registry BEFORE deleting the branch, not after' {
        # A gate that runs after `git branch -D` is decorative.
        $gate = $script:RemoveFn.IndexOf('Test-WorktreeStillRegistered')
        $del  = $script:RemoveFn.IndexOf('git branch $BranchFlag')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeLessThan $del
    }
    It 'fails closed when the post-remove listing itself fails' {
        # "I could not ask git" is not "the worktree is gone" - keep the branch (the #277 rule).
        ($script:RemoveFn -match '\$LASTEXITCODE -ne 0') | Should -BeTrue
    }
}

Describe 'Select-BranchPr (which PR speaks for this tip)' {
    It 'prefers the PR whose head IS our tip over the newest one' {
        # The -TakeOver trap: a newer PR on a reused branch name must not outrank the real one.
        $prs = @((New-Pr -Number 9 -HeadRefOid $script:Tip), (New-Pr -Number 99 -HeadRefOid $script:Other))
        (Select-BranchPr -Prs $prs -Tip $script:Tip).number | Should -Be 9
    }
    It 'falls back to the newest PR when none matches the tip' {
        $prs = @((New-Pr -Number 9 -HeadRefOid $script:Other), (New-Pr -Number 99 -HeadRefOid $script:Other))
        (Select-BranchPr -Prs $prs -Tip $script:Tip).number | Should -Be 99
    }
    It 'returns nothing when the branch has no PR at all' {
        Select-BranchPr -Prs @() -Tip $script:Tip | Should -BeNullOrEmpty
    }
}

Describe 'Get-BranchClass (the merge verdict)' {
    It 'classifies a MERGED PR whose head is our tip as merged and deletable' {
        $r = Invoke-Classify @{ Prs = @(New-Pr -Number 7 -State 'MERGED' -HeadRefOid $script:Tip) }
        $r.Class     | Should -Be 'merged'
        $r.Deletable | Should -BeTrue
        $r.Pr        | Should -Be 7
    }
    It 'does NOT trust a MERGED PR whose head is a different commit' {
        # The exact trap: an old merged PR must not vouch for commits it never contained.
        $r = Invoke-Classify @{ Prs = @(New-Pr -State 'MERGED' -HeadRefOid $script:Other) }
        $r.Class     | Should -Be 'merged-advanced'
        $r.Deletable | Should -BeFalse
    }
    It 'never marks an OPEN PR branch deletable' {
        $r = Invoke-Classify @{ Prs = @(New-Pr -State 'OPEN' -HeadRefOid $script:Tip) }
        $r.Class     | Should -Be 'in-review'
        $r.Deletable | Should -BeFalse
    }
    It 'surfaces a CLOSED unmerged PR for a decision, never for auto-deletion' {
        $r = Invoke-Classify @{ Prs = @(New-Pr -State 'CLOSED' -HeadRefOid $script:Tip) }
        $r.Class     | Should -Be 'closed-unmerged'
        $r.Deletable | Should -BeFalse
    }
    It 'ignores ancestry entirely: a squash-merged branch is merged only because the PR says so' {
        # There is no ancestry input at all. This test documents that on purpose: if someone
        # adds a `--merged` signal, they must change this contract deliberately.
        (Get-Command Get-BranchClass).Parameters.Keys | Should -Not -Contain 'Merged'
        (Get-Command Get-BranchClass).Parameters.Keys | Should -Not -Contain 'IsAncestor'
    }
}

Describe 'Get-BranchClass (branches with no PR)' {
    It 'classifies a branch older than StaleDays as stale' {
        $r = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-45) }
        $r.Class     | Should -Be 'stale'
        $r.AgeDays   | Should -Be 45
        $r.Deletable | Should -BeFalse
    }
    It 'classifies a recent branch as working, not stale' {
        $r = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-3) }
        $r.Class | Should -Be 'working'
    }
    It 'respects a custom StaleDays threshold' {
        $r = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-10); StaleDays = 5 }
        $r.Class | Should -Be 'stale'
    }
    It 'does not call a branch stale exactly at the threshold' {
        $r = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-30); StaleDays = 30 }
        $r.Class | Should -Be 'working'
    }
    It 'reports a dirty worktree as an expected keep (#276), not as stale' {
        $r = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-99); Dirty = 'dirty' }
        $r.Class     | Should -Be 'dirty'
        $r.Deletable | Should -BeFalse
    }
    It 'fails closed: an unreadable worktree is never treated as clean' {
        $r = Invoke-Classify @{ Dirty = 'unknown' }
        $r.Class | Should -Be 'dirty'
        $r.Reason | Should -Match 'no pude comprobar'
    }
}

Describe 'Get-WorktreeDirtyState (the last guard before --force)' {
    # Raised by the Codex review of PR #280: the dangerous side-effect paths were not pinned.
    It 'reports a clean worktree as clean' {
        Get-WorktreeDirtyState -ExitCode 0 -StatusLines @() | Should -Be 'clean'
    }
    It 'reports any status output as dirty' {
        Get-WorktreeDirtyState -ExitCode 0 -StatusLines @('?? scratch.txt') | Should -Be 'dirty'
    }
    It 'treats a git failure as unknown, never clean' {
        Get-WorktreeDirtyState -ExitCode 128 -StatusLines @() | Should -Be 'unknown'
    }
    It 'treats a missing worktree directory as unknown, never clean' {
        Get-WorktreeDirtyState -ExitCode 0 -StatusLines @() -PathExists $false | Should -Be 'unknown'
    }
    It 'is not fooled by whitespace-only output' {
        Get-WorktreeDirtyState -ExitCode 0 -StatusLines @('', '   ') | Should -Be 'clean'
    }
    It 'asks git for ALL untracked files rather than inheriting status.showUntrackedFiles' {
        # With `status.showUntrackedFiles=no` a bare --porcelain calls a worktree full of
        # untracked scratch files CLEAN, and the removal runs --force. Pin the flag at the call.
        $src = Get-Content $script:Script -Raw
        $src | Should -Match 'status --porcelain --untracked-files=all'
    }
}

Describe 'Get-BranchClass (the session registry may only protect)' {
    It 'marks a branch with a live session as active and never deletable' {
        $r = Invoke-Classify @{ HasLiveSession = $true; CommitDate = $script:Now.AddDays(-99) }
        $r.Class     | Should -Be 'active'
        $r.Deletable | Should -BeFalse
    }
    It 'refuses to delete even a proven-merged branch while a session is live on it' {
        # The registry cannot create work, but it must be able to veto destroying it.
        $r = Invoke-Classify @{ Prs = @(New-Pr -State 'MERGED' -HeadRefOid $script:Tip); HasLiveSession = $true }
        $r.Class     | Should -Be 'merged'
        $r.Deletable | Should -BeFalse
    }
    It 'classifies identically with and without the registry when no session is live' {
        # sessions.json is not an input to what EXISTS - only to what is protected.
        $a = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-45); HasLiveSession = $false }
        $b = Invoke-Classify @{ CommitDate = $script:Now.AddDays(-45) }
        $a.Class | Should -Be $b.Class
    }
}

Describe 'the -Fix terminal guard and -Auto (#285)' {
    # The original guard used [Environment]::UserInteractive, which returns TRUE under
    # `pwsh -NonInteractive`. So it never fired and Read-Host blew up mid-walk - precisely
    # what it was written to prevent. Found by actually running -Fix.
    It 'does not use UserInteractive, which is true even in NonInteractive mode' {
        $src = Get-Content $script:Script -Raw
        $src | Should -Not -Match '\[Environment\]::UserInteractive'
        $src | Should -Not -Match '\[System\.Environment\]::UserInteractive'
    }
    It 'guards up front on redirected stdin and again at the prompt itself' {
        # Two guards because there is no API for -NonInteractive: the catch around Read-Host
        # is the one that actually covers it.
        $src = Get-Content $script:Script -Raw
        $src | Should -Match '\[System\.Console\]::IsInputRedirected'
        $src | Should -Match 'catch \{[\s\S]{0,400}throw \$script:NeedTty'
    }
    It 'passes -AutoOk from exactly one call site, the proven-merged walk' {
        # Counted string matches at first, which broke the moment a COMMENT mentioned -AutoOk -
        # and would equally have missed a real call written differently. Ask the AST which
        # invocations actually pass it: that is the property worth protecting, since a second
        # call site on the unmerged walk would let -Auto delete work that exists nowhere else.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Confirm-Branch' -and
            ($n.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'AutoOk' })
        }, $true))
        $calls.Count | Should -Be 1
        # ...and it is the merged walk, identifiable by its prompt.
        $calls[0].Extent.Text | Should -Match 'mergeado'
    }
    It 'only lets -Auto skip a prompt when that call site opted in' {
        (Get-Content $script:Script -Raw) | Should -Match 'if \(\$Auto -and \$AutoOk\) \{ return \$true \}'
    }
    It 'cannot have -AutoOk switched on by a stray positional argument' {
        # Counting the literal above would not catch `Confirm-Branch "p" ([ref]$x) 'n' $true`.
        # Prove it at the signature instead: the switch is named-only (Codex review, PR #286).
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-Branch' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $fn.Body.ParamBlock.Attributes.Extent.Text -join ' ' | Should -Match 'PositionalBinding\s*=\s*\$false'
        $autoOk = $fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AutoOk' }
        $autoOk | Should -Not -BeNullOrEmpty
        # no Position attribute -> unreachable positionally once PositionalBinding is off
        ($autoOk.Attributes.Extent.Text -join ' ') | Should -Not -Match 'Position\s*='
    }
    It 'skips the unmerged walk entirely under -Auto rather than prompting into the void' {
        $src = Get-Content $script:Script -Raw
        $src | Should -Match '-Auto NO las toca'
    }
}

Describe 'Get-DoctorClassOrder (report contract)' {
    It 'lists merged first - the bulk of the pile and the only safely deletable class' {
        (Get-DoctorClassOrder)[0].Class | Should -Be 'merged'
    }
    It 'covers every class the classifier can emit' {
        # Guards against a new class being invented but never rendered.
        $rendered = @((Get-DoctorClassOrder).Class)
        foreach ($c in @('merged','merged-advanced','in-review','closed-unmerged','active','dirty','stale','working')) {
            $rendered | Should -Contain $c
        }
    }
}
