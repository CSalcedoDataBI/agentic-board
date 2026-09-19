#Requires -Modules Pester
<#  A brake-armed run whose PR ended up MERGED (#517, #518).

    #517: the supervisor DETECTS the situation from the observable record (the marker the launcher
    wrote + the PR state) instead of trusting the agent to report its own breach.
    #518: auto-clean REFUSES to tear such a session down, because the marker, the denial log and the
    worktree all live in the directory the teardown removes.

    Both only ADD a detection / a refusal. Real marker files (written by Set-BrakeArmedState, the
    launcher's own writer), a real git repo with a real linked worktree, a real registry file. #>

BeforeAll {
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Brake-Guard.ps1' | Resolve-Path)
    $env:ABIOS_BRAKEGUARD_DOTSOURCE = ''
    $env:ABIOS_FLEETSUPERVISOR_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Supervisor.ps1' | Resolve-Path)
    $env:ABIOS_FLEETSUPERVISOR_DOTSOURCE = ''
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path)
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    function script:New-ArmedDir {
        param([string[]]$Irreversible = @('merge', 'deploy'), [bool]$BudgetOnly = $false, [int]$Budget = 0)
        $d = Join-Path $TestDrive ('armed' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d | Out-Null
        Set-BrakeArmedState -WorkPath $d -Armed $true -Issue 30 -Irreversible $Irreversible -ArmedAt '2026-09-18 10:00:00' `
            -Branch 'issue-30-x' -BudgetOnly $BudgetOnly -BudgetMinutes $Budget | Out-Null
        return $d
    }
}

Describe 'Read-BrakeMarkerAt reads THIS worktree only' {
    It 'returns the marker of the directory itself' {
        $d = New-ArmedDir
        (Read-BrakeMarkerAt -WorkPath $d).issue | Should -Be 30
    }
    It 'does NOT return a marker that sits in an ANCESTOR (that run is somebody else''s)' {
        $parent = New-ArmedDir
        $child = Join-Path $parent 'sub'
        New-Item -ItemType Directory -Path $child | Out-Null
        Read-BrakeMarkerAt -WorkPath $child | Should -BeNullOrEmpty
        # ...while the hook's walker still finds it: the hook's behaviour is untouched.
        (Read-BrakeMarker -StartDir $child).issue | Should -Be 30
    }
    It 'returns $null with no marker, and an unreadable marker is armed with the full vocabulary' {
        $none = Join-Path $TestDrive 'nomarker'; New-Item -ItemType Directory -Path $none | Out-Null
        Read-BrakeMarkerAt -WorkPath $none | Should -BeNullOrEmpty
        $bad = New-ArmedDir
        Set-Content -LiteralPath (Get-BrakeMarkerPath -WorkPath $bad) -Value '{ not json'
        $m = Read-BrakeMarkerAt -WorkPath $bad
        $m.unreadable | Should -BeTrue
        Test-BrakeMarkerBrakesMerge -Marker $m | Should -BeTrue
    }
}

Describe 'Test-BrakeMarkerBrakesMerge' {
    It 'is true when merge is on the contract''s list'  { Test-BrakeMarkerBrakesMerge -Marker (Read-BrakeMarkerAt -WorkPath (New-ArmedDir @('merge'))) | Should -BeTrue }
    It 'is false when the list omits merge'            { Test-BrakeMarkerBrakesMerge -Marker (Read-BrakeMarkerAt -WorkPath (New-ArmedDir @('deploy'))) | Should -BeFalse }
    It 'is false for a budget-only marker (merging was allowed)' {
        Test-BrakeMarkerBrakesMerge -Marker (Read-BrakeMarkerAt -WorkPath (New-ArmedDir @() -BudgetOnly $true -Budget 60)) | Should -BeFalse
    }
    It 'is false for no marker' { Test-BrakeMarkerBrakesMerge -Marker $null | Should -BeFalse }
}

Describe 'Fleet supervisor detects a brake-armed run whose PR merged (#517)' {
    BeforeAll {
        function script:New-FleetSess {
            param([int]$Issue = 1, [bool]$Merged = $true, $BrakesMerge = $true, [string]$MergedBy = 'someone', [string]$MergedAt = '2026-09-18T12:00:00Z')
            [pscustomobject]@{ issue = $Issue; pr = "#$($Issue + 100)"; merged = $Merged; ageMin = 5; brakesMerge = $BrakesMerge; mergedBy = $MergedBy; mergedAt = $MergedAt }
        }
    }
    It 'flags an armed session whose PR is merged, with who merged and when' {
        $v = @(Get-BrakeViolations @((New-FleetSess -Issue 7)))
        $v.Count | Should -Be 1
        $v[0].issue | Should -Be 7
        $v[0].mergedBy | Should -Be 'someone'
        $v[0].mergedAt | Should -Be '2026-09-18T12:00:00Z'
    }
    It 'does not flag a merged session that was never armed, or armed WITHOUT braking on merge' {
        @(Get-BrakeViolations @((New-FleetSess -BrakesMerge $false))).Count | Should -Be 0
        @(Get-BrakeViolations @([pscustomobject]@{ issue = 2; pr = '#2'; merged = $true })).Count | Should -Be 0   # legacy row, no brake facts
    }
    It 'does not flag an armed session whose PR is not merged' {
        @(Get-BrakeViolations @((New-FleetSess -Merged $false))).Count | Should -Be 0
    }
    It 'rides on the verdict without changing any other field of it' {
        $v = Get-FleetVerdict @((New-FleetSess -Issue 1), (New-FleetSess -Issue 2 -Merged $false -BrakesMerge $true)) 30 2
        @($v.brakeViolations).Count | Should -Be 1
        $v.complete | Should -BeFalse
        $v.shouldStop | Should -BeFalse
        $v.reason | Should -Be 'in progress'
    }
    It 'names the issue, the PR, who merged and how to judge it' {
        $text = (Format-BrakeViolations @(Get-BrakeViolations @((New-FleetSess -Issue 9 -MergedBy 'alice')))) -join "`n"
        $text | Should -Match '#9 #109 MERGEADO por alice'
        $text | Should -Match 'denials\.jsonl'
    }
    It 'a violation without who/when (GitHub omitted them, or a legacy row) is still flagged, and the report does not invent an actor' {
        $row = [pscustomobject]@{ issue = 4; pr = '#104'; merged = $true; brakesMerge = $true }      # no mergedBy / mergedAt at all
        $v = @(Get-BrakeViolations @($row))
        $v.Count | Should -Be 1
        $v[0].mergedBy | Should -BeNullOrEmpty
        $text = (Format-BrakeViolations $v) -join "`n"
        $text | Should -Match '#4 #104 MERGEADO - la corrida'
        $text | Should -Not -Match ' por '
    }
    It 'Get-SessionBrakeInfo reads the REAL marker of the session''s worktree' {
        $armed = Get-SessionBrakeInfo -WorkPath (New-ArmedDir @('merge'))
        $armed.brakeArmed | Should -BeTrue
        $armed.brakesMerge | Should -BeTrue
        $plain = Join-Path $TestDrive 'plainwt'; New-Item -ItemType Directory -Path $plain | Out-Null
        (Get-SessionBrakeInfo -WorkPath $plain).brakeArmed | Should -BeFalse
        (Get-SessionBrakeInfo -WorkPath '').brakeArmed | Should -BeFalse
    }
}

Describe 'the supervisor attributes a PR to THIS session, not to the branch name (Copilot review of #701)' {
    # -TakeOver reuses issue-<n>-<slug>, so two PRs can share one branch name. The OLD merged one must not
    # be reported as this run's PR: that raised a false brake violation for a relaunch with no PR yet.
    BeforeAll {
        $script:Started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $script:OldPr = [pscustomobject]@{ number = 100; state = 'MERGED'; headRefOid = ('a' * 40); createdAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') }
        $script:NewPr = [pscustomobject]@{ number = 200; state = 'OPEN';   headRefOid = ('b' * 40); createdAt = (Get-Date).AddMinutes(5).ToUniversalTime().ToString('o') }
    }
    It 'a relaunch with NO PR yet does not adopt the old merged PR (the reported false violation)' {
        Select-SessionPr -Prs @($script:OldPr) -Tip ('c' * 40) -StartedAt $script:Started | Should -BeNullOrEmpty
    }
    It 'the PR whose head is this session''s branch tip wins, even against a newer number' {
        (Select-SessionPr -Prs @($script:NewPr, $script:OldPr) -Tip ('a' * 40) -StartedAt $script:Started).number | Should -Be 100
    }
    It 'with two PRs on the name and a moved branch, the one created after the session started is chosen' {
        (Select-SessionPr -Prs @($script:OldPr, $script:NewPr) -Tip ('c' * 40) -StartedAt $script:Started).number | Should -Be 200
    }
    It 'an unparseable session stamp adopts nothing it cannot prove (never an older run''s PR)' {
        Select-SessionPr -Prs @($script:OldPr) -Tip '' -StartedAt 'garbage' | Should -BeNullOrEmpty
    }
    It 'accepts the older minute-granular stamp' {
        (Select-SessionPr -Prs @($script:NewPr) -Tip '' -StartedAt (Get-Date).ToString('yyyy-MM-dd HH:mm')).number | Should -Be 200
    }
    It 'end to end: no violation is raised for a relaunch whose only PR is the old merged one' {
        $mine = Select-SessionPr -Prs @($script:OldPr) -Tip ('c' * 40) -StartedAt $script:Started
        $row = [pscustomobject]@{ issue = 5; pr = $(if ($mine) { "#$($mine.number)" } else { '' }); merged = [bool]($mine -and $mine.state -eq 'MERGED'); brakesMerge = $true }
        @(Get-BrakeViolations @($row)).Count | Should -Be 0
    }
    It 'Resolve-LiveSessions (real code path, a fake gh on PATH) ignores the old merged PR of a reused branch name' {
        $bin = Join-Path $TestDrive 'fakebin'; New-Item -ItemType Directory -Path $bin | Out-Null
        $json = Join-Path $bin 'prs.json'
        @(@{ number = 100; state = 'MERGED'; headRefOid = ('a' * 40); createdAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o'); mergedBy = @{ login = 'old' }; mergedAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') }) |
            ConvertTo-Json -Depth 5 -AsArray | Set-Content $json
        "@type ""$json""" | Set-Content (Join-Path $bin 'gh.cmd') -Encoding ASCII
        $state = Join-Path $TestDrive 'fakestate'; New-Item -ItemType Directory -Path $state | Out-Null
        $wt = Join-Path $TestDrive 'fakewt'; New-Item -ItemType Directory -Path $wt | Out-Null
        Set-BrakeArmedState -WorkPath $wt -Armed $true -Issue 5 -Irreversible @('merge') -ArmedAt '2026-09-18 10:00:00' | Out-Null
        @([pscustomobject]@{ issue = 5; repo = 'o/r'; branch = 'issue-5-x'; workPath = $wt; sessionPid = 0; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) |
            ConvertTo-Json -Depth 4 -AsArray | Set-Content (Join-Path $state 'sessions.json')
        $regFile = Join-Path $state 'sessions.json'
        Mock Get-SessionsFile -MockWith ([scriptblock]::Create("'$regFile'"))   # only WHERE the registry is; Resolve-LiveSessions runs for real
        $oldPath = $env:PATH; $env:PATH = "$bin;$oldPath"
        try { $rows = @(Resolve-LiveSessions) } finally { $env:PATH = $oldPath }
        $rows.Count | Should -Be 1
        $rows[0].prKnown | Should -BeTrue          # gh answered
        $rows[0].pr      | Should -Be ''           # ...and the old PR was NOT adopted
        $rows[0].merged  | Should -BeFalse
        @(Get-BrakeViolations $rows).Count | Should -Be 0
    }
    It 'Get-SessionBranchTip reads the tip from the session''s own worktree, and is empty when it cannot' {
        $repo = Join-Path $TestDrive 'tiprepo'; New-Item -ItemType Directory -Path $repo | Out-Null
        Push-Location $repo
        try {
            git init -q -b main 2>&1 | Out-Null
            'x' | Set-Content a.txt; git add -A 2>&1 | Out-Null
            git -c user.email=t@t -c user.name=t commit -q -m base 2>&1 | Out-Null
            git branch issue-5-x 2>&1 | Out-Null
            $expected = (git rev-parse issue-5-x)
        } finally { Pop-Location }
        Get-SessionBranchTip -WorkPath $repo -Branch 'issue-5-x' | Should -Be $expected
        Get-SessionBranchTip -WorkPath $repo -Branch 'no-such-branch' | Should -Be ''
        Get-SessionBranchTip -WorkPath (Join-Path $TestDrive 'missing') -Branch 'issue-5-x' | Should -Be ''
    }
}
Describe 'auto-clean refuses to tear down a brake-armed session whose PR merged (#518)' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('bk' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Clone = Join-Path $script:Root 'clone'
        New-Item -ItemType Directory -Path $script:Clone -Force | Out-Null
        Push-Location $script:Clone
        git init -q -b main 2>&1 | Out-Null
        'x' | Set-Content (Join-Path $script:Clone 'a.txt')
        git add -A 2>&1 | Out-Null
        git -c user.email=t@t -c user.name=t commit -q -m base 2>&1 | Out-Null
        git branch issue-30-x 2>&1 | Out-Null
        $script:Wt = Join-Path $script:Root 'clone--issue-30'
        git worktree add -q $script:Wt issue-30-x 2>&1 | Out-Null
        $script:Reg = Join-Path $script:Root 'sessions.json'
        $reg = $script:Reg
        Mock Get-SessionRegistryPath -MockWith ([scriptblock]::Create("'$reg'"))
        Mock Find-WtTabShell { $null }
        # A second entry keeps the file non-empty, so this test does not depend on how an EMPTY registry is written.
        @([pscustomobject]@{ issue = 30; branch = 'issue-30-x'; workPath = $script:Wt; sessionPid = 0; via = '' },
          [pscustomobject]@{ issue = 31; branch = 'issue-31-y'; workPath = 'C:\elsewhere'; sessionPid = 0; via = '' }) |
            ConvertTo-Json -Depth 4 -AsArray | Set-Content $script:Reg
        function script:Arm([string[]]$Irr = @('merge', 'deploy')) {
            Set-BrakeArmedState -WorkPath $script:Wt -Armed $true -Issue 30 -Irreversible $Irr -ArmedAt '2026-09-18 10:00:00' -Branch 'issue-30-x' | Out-Null
        }
        function script:New-Sess { [pscustomobject]@{ issue = 30; branch = 'issue-30-x'; workPath = $script:Wt; sessionPid = 0; via = '' } }
    }
    AfterEach { Pop-Location }

    It 'REFUSES: worktree, marker, branch and registry entry all survive, and the reason is named' {
        Arm
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged)
        ($acts -join ' ') | Should -Match 'FRENO armado'
        ($acts -join ' ') | Should -Match '-ForceRemoveWorktree'
        ($acts -join ' ') | Should -Not -Match 'worktree remove'
        Test-Path $script:Wt | Should -BeTrue
        Test-Path (Get-BrakeMarkerPath -WorkPath $script:Wt) | Should -BeTrue      # the evidence is still there
        (git branch --list 'issue-30-x') | Should -Not -BeNullOrEmpty
        (Get-Content $script:Reg -Raw) | Should -Match '"issue": 30'               # not pruned
    }
    It 'refuses BEFORE any teardown step, also under -DryRun (read-only, so the plan is honest)' {
        Arm
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged -DryRun)
        $acts.Count | Should -Be 1
        ($acts -join ' ') | Should -Match 'FRENO armado'
    }
    It 'an UNREADABLE marker is treated as armed: refuses' {
        Arm
        Set-Content -LiteralPath (Get-BrakeMarkerPath -WorkPath $script:Wt) -Value '{ not json'
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged)
        ($acts -join ' ') | Should -Match 'FRENO armado'
        Test-Path $script:Wt | Should -BeTrue
    }
    It '-ForceRemoveWorktree is the human''s deliberate way past it' {
        Arm
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged -ForceRemoveWorktree)
        ($acts -join ' ') | Should -Match 'git worktree remove --force'
        Test-Path $script:Wt | Should -BeFalse
        (git branch --list 'issue-30-x') | Should -BeNullOrEmpty
    }
    It 'CONTROL: a run that was never armed is torn down as before' {
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged)
        ($acts -join ' ') | Should -Not -Match 'FRENO'
        Test-Path $script:Wt | Should -BeFalse
        (Get-Content $script:Reg -Raw) | Should -Not -Match '"issue": 30'
    }
    It 'CONTROL: armed but NOT braking on merge (deploy only) is torn down as before' {
        Arm @('deploy')
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -PrMerged)
        ($acts -join ' ') | Should -Not -Match 'FRENO'
        Test-Path $script:Wt | Should -BeFalse
    }
    It 'CONTROL: armed, but the session did NOT end with a merged PR - the refusal is about merges only' {
        Arm
        $acts = @(Invoke-SessionCleanup -Session (New-Sess) -DryRun)     # no -PrMerged
        ($acts -join ' ') | Should -Not -Match 'FRENO'
        # The ordinary path runs (here the marker file itself makes the worktree dirty, so the #276 guard speaks).
        ($acts -join ' ') | Should -Match 'sin commitear'
    }
}
