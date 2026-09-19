#Requires -Modules Pester
<#  Session liveness: a recycled PID must not keep a dead session alive (#520), and a wt-launched
    session must be tracked by its OWN tab shell, not the launching shell's parent (#557).

    These tests drive real processes: the Pester host itself (a live PID with a real StartTime) and
    a real `pwsh -File launch-<n>.ps1` process that stands in for a wt tab shell. Nothing here mocks
    the function under test. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    $script:MyStart = (Get-Process -Id $PID).StartTime
    # A registration stamp from an hour BEFORE this process existed: this process cannot be that
    # session, exactly as a recycled PID cannot be the session that first held the number.
    $script:StampBefore = $script:MyStart.AddHours(-1).ToString('yyyy-MM-dd HH:mm:ss')
    # A stamp taken well after this process started: the normal case for a real session.
    $script:StampAfter  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # A real `pwsh` whose command line names launch-<issue>.ps1, i.e. what a wt tab shell looks like.
    function Start-FakeTabShell {
        param([int]$Issue, [string]$Dir)
        $file = Join-Path $Dir "launch-$Issue.ps1"
        'Start-Sleep -Seconds 300' | Set-Content -LiteralPath $file
        Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $file) -PassThru -WindowStyle Hidden
    }
    $script:Shells = @()
}

AfterAll {
    foreach ($s in $script:Shells) { try { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

Describe 'Test-SessionStartConsistent (pure - #520)' {
    It 'accepts a process that started before the registration stamp' {
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-15 12:00:00') -Started '2026-07-15 12:17:00' | Should -BeTrue
    }
    It 'REJECTS a process that started after the registration stamp (a recycled PID)' {
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-30 08:23:40') -Started '2026-07-15 12:17:00' | Should -BeFalse
    }
    It 'tolerates the stamp truncating to whole seconds' {
        # Process born 12:17:45.900, registered 12:17:46.100 -> stamp "12:17:46"; born 12:17:46.500 -> still ok.
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-15 12:17:46.500') -Started '2026-07-15 12:17:46' | Should -BeTrue
    }
    It 'tolerates an OLD minute-granular stamp (whole minutes): a process from that minute is not rejected' {
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-15 12:17:40') -Started '2026-07-15 12:17' | Should -BeTrue
    }
    It 'still rejects a process that started minutes after an old minute-granular stamp' {
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-15 12:19:10') -Started '2026-07-15 12:17' | Should -BeFalse
    }
    It 'does not condemn a genuine session on the night the clocks go BACK (ambiguous hour)' {
        # US Eastern, 2025-11-02: 01:00-01:59 happens twice. A process started at 01:30 in the FIRST
        # pass reads later than a stamp taken at 01:10 in the SECOND pass, though it started earlier.
        $tz = $null
        foreach ($id in 'Eastern Standard Time', 'America/New_York') {
            try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { }
        }
        if (-not $tz) { Set-ItResult -Skipped -Because 'no DST time zone available on this host'; return }
        Test-SessionStartConsistent -ProcessStart ([datetime]'2025-11-02 01:30:00') -Started '2025-11-02 01:10:00' -TimeZone $tz | Should -BeTrue
        # ...and outside the ambiguous hour the same gap is still a recycled PID.
        Test-SessionStartConsistent -ProcessStart ([datetime]'2025-11-02 04:30:00') -Started '2025-11-02 04:10:00' -TimeZone $tz | Should -BeFalse
    }
    It 'cannot tell -> consistent (missing start time, missing stamp, unparseable stamp)' {
        Test-SessionStartConsistent -ProcessStart $null -Started '2026-07-15 12:17:00' | Should -BeTrue
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-30 08:23:40') -Started '' | Should -BeTrue
        Test-SessionStartConsistent -ProcessStart ([datetime]'2026-07-30 08:23:40') -Started 'not a date' | Should -BeTrue
    }
}

Describe 'Get-SessionLivePid (#520 recycled PID, #557 wt tab shell)' {
    It 'returns the stored PID for a live process that started before the stamp' {
        Get-SessionLivePid ([pscustomobject]@{ issue = 1; sessionPid = $PID; started = $script:StampAfter }) | Should -Be $PID
    }
    It 'returns 0 when the PID exists but started AFTER the stamp (recycled)' {
        Get-SessionLivePid ([pscustomobject]@{ issue = 1; sessionPid = $PID; started = $script:StampBefore }) | Should -Be 0
    }
    It 'keeps a legacy entry with no stamp alive while its PID exists' {
        Get-SessionLivePid ([pscustomobject]@{ issue = 1; sessionPid = $PID }) | Should -Be $PID
    }
    It 'returns 0 for a PID that does not exist' {
        Get-SessionLivePid ([pscustomobject]@{ issue = 1; sessionPid = 999999; started = $script:StampAfter }) | Should -Be 0
    }
    It 'a wt entry with no stored PID resolves to its tab shell through its launch script' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            $entry = [pscustomobject]@{ issue = $issue; sessionPid = 0; via = 'wt'; started = $script:StampAfter }
            # The process needs a moment to appear in CIM.
            $found = 0
            for ($i = 0; $i -lt 40 -and $found -le 0; $i++) { $found = Get-SessionLivePid $entry; if ($found -le 0) { Start-Sleep -Milliseconds 250 } }
            $found | Should -Be $tab.Id
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a wt entry whose stored PID is dead (the launcher shell exited) is STILL alive while its tab shell runs' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            $entry = [pscustomobject]@{ issue = $issue; sessionPid = 999999; via = 'wt'; started = $script:StampAfter }
            $found = 0
            for ($i = 0; $i -lt 40 -and $found -le 0; $i++) { $found = Get-SessionLivePid $entry; if ($found -le 0) { Start-Sleep -Milliseconds 250 } }
            $found | Should -Be $tab.Id
            # ... and it is gone once the tab shell is.
            Stop-Process -Id $tab.Id -Force
            $tab.WaitForExit(10000) | Out-Null
            Get-SessionLivePid $entry | Should -Be 0
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a LEGACY wt entry (stored PID = the launching shell, alive and older) is NOT alive when no tab shell exists' {
        # Entries written before #557 hold the launcher's parent. That process is live and started
        # before the stamp, so the start-time check alone would keep the dead session alive for as
        # long as the launching shell lives. Here $PID stands in for that shell.
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        Get-SessionLivePid ([pscustomobject]@{ issue = $issue; sessionPid = $PID; via = 'wt'; started = $script:StampAfter }) | Should -Be 0
    }
    It 'a LEGACY wt entry resolves to the real tab shell, not the launcher, when the tab is running' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            $entry = [pscustomobject]@{ issue = $issue; sessionPid = $PID; via = 'wt'; started = $script:StampAfter }
            $found = 0
            for ($i = 0; $i -lt 40 -and $found -le 0; $i++) { $found = Get-SessionLivePid $entry; if ($found -le 0) { Start-Sleep -Milliseconds 250 } }
            $found | Should -Be $tab.Id
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a wt entry whose stored PID IS the tab shell keeps that PID' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            Start-Sleep -Milliseconds 1500
            $entry = [pscustomobject]@{ issue = $issue; sessionPid = $tab.Id; via = 'wt'; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            Get-SessionLivePid $entry | Should -Be $tab.Id
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a wt entry does NOT latch onto an OLDER tab shell of the same issue left open by -NoExit' {
        # The stamp is 10 minutes AFTER the shell was created, i.e. the shell belongs to an earlier
        # run. Without the creation-time bound the fallback resurrected the dead session.
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            Start-Sleep -Seconds 2
            $entry = [pscustomobject]@{ issue = $issue; sessionPid = 0; via = 'wt'; started = (Get-Date).AddMinutes(10).ToString('yyyy-MM-dd HH:mm:ss') }
            Get-SessionLivePid $entry | Should -Be 0
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'a NON-wt entry never falls back to a launch-script lookup' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            Start-Sleep -Seconds 2
            Get-SessionLivePid ([pscustomobject]@{ issue = $issue; sessionPid = 999999; via = 'pwsh'; started = $script:StampAfter }) | Should -Be 0
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Read-SessionRegistry drops a recycled PID but keeps the file (#520)' {
    It 'returns the genuine session, not the one whose PID was recycled, and does not rewrite the file' {
        $tmp = Join-Path $TestDrive 'recycled-sessions.json'
        @(
            [pscustomobject]@{ issue = 281; sessionPid = $PID; started = $script:StampBefore },   # recycled
            [pscustomobject]@{ issue = 285; sessionPid = $PID; started = $script:StampAfter }     # genuine
        ) | ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
        Mock Get-SessionRegistryPath { $tmp }
        $live = @(Read-SessionRegistry)
        $live.Count | Should -Be 1
        [int]$live[0].issue | Should -Be 285
        @(Get-Content $tmp -Raw | ConvertFrom-Json).Count | Should -Be 2
    }
    It 'shows a wt entry through its tab shell with the REAL pid, and drops it when the shell is gone' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            $tmp = Join-Path $TestDrive 'wt-sessions.json'
            @([pscustomobject]@{ issue = $issue; sessionPid = 999999; via = 'wt'; started = $script:StampAfter }) |
                ConvertTo-Json -Depth 4 -AsArray | Set-Content $tmp
            Mock Get-SessionRegistryPath { $tmp }
            $live = @()
            for ($i = 0; $i -lt 40 -and $live.Count -eq 0; $i++) { $live = @(Read-SessionRegistry); if ($live.Count -eq 0) { Start-Sleep -Milliseconds 250 } }
            $live.Count | Should -Be 1
            [int]$live[0].sessionPid | Should -Be $tab.Id
            # The correction is on the returned copy only.
            [int]((Get-Content $tmp -Raw | ConvertFrom-Json)[0].sessionPid) | Should -Be 999999
            Stop-Process -Id $tab.Id -Force
            $tab.WaitForExit(10000) | Out-Null
            @(Read-SessionRegistry).Count | Should -Be 0
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-SessionLiveStatus uses real liveness (#520)' {
    It 'reports a recycled-PID session as FINISHED (proceso terminado), not "en progreso"' {
        $s = [pscustomobject]@{ issue = 281; sessionPid = $PID; started = $script:StampBefore }   # no repo -> no gh
        $st = Get-SessionLiveStatus $s
        $st.done   | Should -BeTrue
        $st.reason | Should -Be 'proceso terminado'
    }
    It 'reports the same session as in progress while its PID is genuinely its own' {
        $s = [pscustomobject]@{ issue = 281; sessionPid = $PID; started = $script:StampAfter }
        (Get-SessionLiveStatus $s).done | Should -BeFalse
    }
}

Describe 'Invoke-SessionWatch zombie prune honours the start-time check (#520)' {
    It 'prunes a recycled-PID session whose worktree is gone, without polling gh' {
        $script:statusCalls = 0
        $s = [pscustomobject]@{ issue = 88; sessionPid = $PID; started = $script:StampBefore; workPath = (Join-Path $TestDrive 'missing-worktree') }
        $r = Invoke-SessionWatch -DryRun -SuperviseEvery 0 -ReadSessions { @($s) } `
                -GetStatus { param($x) $script:statusCalls++; [pscustomobject]@{ done = $true; reason = 'x'; merged = $false } } `
                -Now { Get-Date } -Sleep { param($sec) }
        $r.allDone | Should -BeTrue
        $script:statusCalls | Should -Be 0
    }
    It 'prunes a wt session recorded with NO pid (tab never found) once its worktree is gone' {
        $script:statusCalls = 0
        $s = [pscustomobject]@{ issue = 88; sessionPid = 0; via = 'wt'; started = $script:StampAfter; workPath = (Join-Path $TestDrive 'missing-worktree') }
        Invoke-SessionWatch -DryRun -SuperviseEvery 0 -ReadSessions { @($s) } `
                -GetStatus { param($x) $script:statusCalls++; [pscustomobject]@{ done = $true; reason = 'x'; merged = $false } } `
                -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        $script:statusCalls | Should -Be 0
    }
    It 'does NOT prune the same session when its PID is genuinely its own' {
        $script:statusCalls = 0
        $s = [pscustomobject]@{ issue = 88; sessionPid = $PID; started = $script:StampAfter; workPath = (Join-Path $TestDrive 'missing-worktree') }
        Invoke-SessionWatch -DryRun -SuperviseEvery 0 -ReadSessions { @($s) } `
                -GetStatus { param($x) $script:statusCalls++; [pscustomobject]@{ done = $true; reason = 'x'; merged = $false } } `
                -Now { Get-Date } -Sleep { param($sec) } | Out-Null
        $script:statusCalls | Should -Be 1
    }
}

Describe 'Write-SessionRegistryEntry never records the launcher''s parent for a wt session (#557)' {
    It 'a wt entry with no PID is written with sessionPid 0, not the parent of the launching shell' {
        $tmp = Join-Path $TestDrive 'w1.json'
        Mock Get-SessionRegistryPath { $tmp }
        Write-SessionRegistryEntry -IssueNum 5 -Via 'wt' -Cli 'claude' -FleetSession '5-abc'
        $e = @(Get-Content $tmp -Raw | ConvertFrom-Json)[0]
        [int]$e.sessionPid | Should -Be 0
        $e.via | Should -Be 'wt'
    }
    It 'a wt entry WITH a resolved tab-shell PID records exactly it' {
        $tmp = Join-Path $TestDrive 'w2.json'
        Mock Get-SessionRegistryPath { $tmp }
        Write-SessionRegistryEntry -IssueNum 5 -SessionPid 4321 -Via 'wt'
        [int](@(Get-Content $tmp -Raw | ConvertFrom-Json)[0].sessionPid) | Should -Be 4321
    }
    It 'an in-place session (no via, no PID) still records the host parent PID' {
        $tmp = Join-Path $TestDrive 'w3.json'
        Mock Get-SessionRegistryPath { $tmp }
        $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
        Write-SessionRegistryEntry -IssueNum 6 -Branch 'issue-6-x' -WorkPath 'C:\wt\6'
        [int](@(Get-Content $tmp -Raw | ConvertFrom-Json)[0].sessionPid) | Should -Be $parent
    }
}

Describe 'Resolve-WtSessionPid (#557)' {
    BeforeAll {
        $script:NoSleep = { param($ms) }
        function New-Proc($id, $cmd, $created) { [pscustomobject]@{ ProcessId = $id; CommandLine = $cmd; CreationDate = $created } }
    }
    It 'finds the tab shell running its launch script' {
        $now = Get-Date
        $list = { @(
            (New-Proc 100 'pwsh -NoProfile' $now),
            (New-Proc 200 'pwsh -NoExit -File C:\x\launch-42.ps1' $now)
        ) }
        Resolve-WtSessionPid -IssueNum 42 -NotBefore $now.AddMinutes(-1) -ListProcesses $list -Sleep $script:NoSleep | Should -Be 200
    }
    It 'ignores an older shell of the same issue left open by -NoExit (created before the launch)' {
        $now = Get-Date
        $list = { @(
            (New-Proc 200 'pwsh -NoExit -File C:\x\launch-42.ps1' $now.AddHours(-3)),
            (New-Proc 300 'pwsh -NoExit -File C:\x\launch-42.ps1' $now)
        ) }
        Resolve-WtSessionPid -IssueNum 42 -NotBefore $now.AddMinutes(-1) -ListProcesses $list -Sleep $script:NoSleep | Should -Be 300
    }
    It 'returns 0, and does not take the stale shell, when only an older shell exists' {
        $now = Get-Date
        $list = { @( (New-Proc 200 'pwsh -NoExit -File C:\x\launch-42.ps1' $now.AddHours(-3)) ) }
        Resolve-WtSessionPid -IssueNum 42 -NotBefore $now.AddMinutes(-1) -MaxAttempts 3 -ListProcesses $list -Sleep $script:NoSleep | Should -Be 0
    }
    It 'waits for a tab that takes a few polls to appear' {
        $script:polls = 0
        $now = Get-Date
        $list = {
            $script:polls++
            if ($script:polls -lt 3) { @() } else { @( (New-Proc 500 'pwsh -NoExit -File C:\x\launch-42.ps1' (Get-Date)) ) }
        }
        Resolve-WtSessionPid -IssueNum 42 -NotBefore $now.AddMinutes(-1) -ListProcesses $list -Sleep $script:NoSleep | Should -Be 500
        $script:polls | Should -Be 3
    }
    It 'returns 0 when it never appears (and does not match another issue)' {
        $now = Get-Date
        $list = { @( (New-Proc 600 'pwsh -NoExit -File C:\x\launch-420.ps1' (Get-Date)) ) }
        Resolve-WtSessionPid -IssueNum 42 -NotBefore $now.AddMinutes(-1) -MaxAttempts 3 -ListProcesses $list -Sleep $script:NoSleep | Should -Be 0
    }
}

Describe 'Register-LaunchedSession (#557)' {
    It 'wt: records the real tab shell found by its launch script' {
        $issue = Get-Random -Minimum 700000 -Maximum 799999
        $tmp = Join-Path $TestDrive 'reg-wt.json'
        Mock Get-SessionRegistryPath { $tmp }
        $tab = Start-FakeTabShell -Issue $issue -Dir $TestDrive
        $script:Shells += $tab
        try {
            $spawn = [pscustomobject]@{ usesWt = $true; process = $null; launchedAt = (Get-Date).AddMinutes(-1) }
            Register-LaunchedSession -Spawn $spawn -IssueNum $issue -FleetSession "$issue-abc"
            $e = @(Get-Content $tmp -Raw | ConvertFrom-Json)[0]
            [int]$e.sessionPid | Should -Be $tab.Id
            $e.via | Should -Be 'wt'
            $e.fleetSession | Should -Be "$issue-abc"
        } finally { Stop-Process -Id $tab.Id -Force -ErrorAction SilentlyContinue }
    }
    It 'wt with no tab shell: records NO pid rather than the launcher''s parent' {
        $tmp = Join-Path $TestDrive 'reg-wt-none.json'
        Mock Get-SessionRegistryPath { $tmp }
        Mock Resolve-WtSessionPid { 0 }
        $spawn = [pscustomobject]@{ usesWt = $true; process = $null; launchedAt = (Get-Date) }
        Register-LaunchedSession -Spawn $spawn -IssueNum 77 -FleetSession '77-abc'
        [int](@(Get-Content $tmp -Raw | ConvertFrom-Json)[0].sessionPid) | Should -Be 0
    }
    It 'pwsh window: still records the spawned process id' {
        $tmp = Join-Path $TestDrive 'reg-pwsh.json'
        Mock Get-SessionRegistryPath { $tmp }
        $spawn = [pscustomobject]@{ usesWt = $false; process = [pscustomobject]@{ Id = $PID } }
        Register-LaunchedSession -Spawn $spawn -IssueNum 78 -FleetSession '78-abc'
        $e = @(Get-Content $tmp -Raw | ConvertFrom-Json)[0]
        [int]$e.sessionPid | Should -Be $PID
        $e.via | Should -Be 'pwsh'
    }
}
