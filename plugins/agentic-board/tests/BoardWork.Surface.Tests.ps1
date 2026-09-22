#Requires -Modules Pester
<#  Tests for the fleet launch surfaces (#710 phase P1): the sessions.json lock, the -NoCreate read
    path, the 'app' surface's dispatch manifest, -RegisterSession, and the host-managed liveness
    sentinel. The lock test drives TWO REAL pwsh processes writing sessions.json at once - nothing
    here mocks the function under test for that case. #>

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

Describe 'Get-HostManagedPidMarker' {
    It 'is a fixed, positive, non-zero sentinel (never a real PID)' {
        Get-HostManagedPidMarker | Should -BeGreaterThan 0
        Get-HostManagedPidMarker | Should -Be (Get-HostManagedPidMarker)
    }
}

Describe 'Invoke-WithSessionRegistryLock (single-process behaviour)' {
    It 'runs the body exactly once and returns its value' {
        # $script: (not a bare local $var): the scriptblock literal is bound to the FILE's session
        # state, so it resolves through the script scope, not the dynamic It-block scope a plain
        # local variable would need - the same reason injectable scriptblocks elsewhere in this
        # suite (e.g. Invoke-SessionWatch's -ReadSessions) close over $script: state, not locals.
        $script:LockCalls = 0
        $r = Invoke-WithSessionRegistryLock -Path 'C:/does/not/matter' -Body { $script:LockCalls++; 'ok' }
        $script:LockCalls | Should -Be 1
        $r | Should -Be 'ok'
    }
    It 'runs the body unlocked (no throw) when -Path is empty - nothing shared to protect' {
        $script:LockCalls = 0
        Invoke-WithSessionRegistryLock -Path '' -Body { $script:LockCalls++ } | Out-Null
        $script:LockCalls | Should -Be 1
    }
    It 'two SEQUENTIAL calls on the same path both succeed (the mutex releases cleanly)' {
        1..5 | ForEach-Object {
            Invoke-WithSessionRegistryLock -Path 'C:/same/path/for/every/call' -Body { 'x' } | Should -Be 'x'
        }
    }
}

Describe 'Resolve-LockPathForm canonicalizes the lock name (external review round 1)' {
    It 'the SAME real file resolves to the SAME canonical form through a short (8.3) and a long path' {
        $repo = New-Throwaway 'CanonPathTest'
        $long = Join-Path $repo '.agentic-board'
        New-Item -ItemType Directory -Path $long -Force | Out-Null
        $file = Join-Path $long 'sessions.json'
        Set-Content -LiteralPath $file -Value '[]'
        # Build an 8.3 short form of the SAME directory the way %TEMP%-derived paths do in the wild
        # (this repo's own comments document Windows actually doing this - CRISTO~1 for Cristobal).
        $fsObj = New-Object -ComObject Scripting.FileSystemObject
        $shortDir = $fsObj.GetFolder($long).ShortPath
        if ($shortDir -and $shortDir -ne $long) {
            $shortFile = Join-Path $shortDir 'sessions.json'
            (Resolve-LockPathForm $file) | Should -Be (Resolve-LockPathForm $shortFile)
        } else {
            Set-ItResult -Skipped -Because 'this filesystem/host did not produce a distinct 8.3 short form to compare against'
        }
    }
    It 'falls back to the raw path when the parent directory cannot be resolved' {
        Resolve-LockPathForm 'Z:\does\not\exist\sessions.json' | Should -Be 'Z:\does\not\exist\sessions.json'
    }
    It 'returns empty for an empty path' {
        Resolve-LockPathForm '' | Should -Be ''
    }
}

Describe 'sessions.json lock survives TWO REAL processes writing at once (#710 decision 5)' {
    It 'every row from both processes survives - no read-modify-write clobbers the other''s rows' {
        $repo = New-Throwaway 'lock-concurrency'
        $writerPath = Join-Path $TestDrive 'surface-lock-writer.ps1'
        @'
param([string]$RepoPath, [string]$ScriptPath, [int]$StartIssue, [int]$Count)
Set-Location -LiteralPath $RepoPath
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
. $ScriptPath
$env:ABIOS_BOARDWORK_DOTSOURCE = ''
for ($i = 0; $i -lt $Count; $i++) {
    $n = $StartIssue + $i
    Write-SessionRegistryEntry -IssueNum $n -Branch "issue-$n-x" -WorkPath "C:/w/$n" -Repo 'o/r' -SessionPid (20000 + $n) -Via 'pwsh'
}
'@ | Set-Content -LiteralPath $writerPath -Encoding UTF8

        $countEach = 25
        $p1 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $writerPath, '-RepoPath', $repo, '-ScriptPath', "$script:Script", '-StartIssue', '1', '-Count', "$countEach") -PassThru -WindowStyle Hidden
        $p2 = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $writerPath, '-RepoPath', $repo, '-ScriptPath', "$script:Script", '-StartIssue', '5000', '-Count', "$countEach") -PassThru -WindowStyle Hidden
        $p1.WaitForExit(90000) | Out-Null
        $p2.WaitForExit(90000) | Out-Null
        $p1.HasExited | Should -BeTrue -Because 'writer process 1 must finish within the timeout'
        $p2.HasExited | Should -BeTrue -Because 'writer process 2 must finish within the timeout'

        Push-Location $repo
        try { $rows = @(Read-SessionRegistryRaw) } finally { Pop-Location }
        $rows.Count | Should -Be ($countEach * 2) -Because 'a lost write would leave fewer rows than the two processes wrote'
        (@($rows.issue) | Select-Object -Unique).Count | Should -Be ($countEach * 2) -Because 'every issue number from both processes must be present exactly once'
        $expected = @(1..$countEach) + @(5000..(5000 + $countEach - 1))
        (@($rows.issue) | Sort-Object) | Should -Be (@($expected) | Sort-Object)
    }
}

Describe 'Get-SessionRegistryPath -NoCreate never creates .agentic-board/ (#710 decision 6)' {
    It 'returns the would-be path without creating the directory' {
        $repo = New-Throwaway 'noc-path'
        Push-Location $repo
        try {
            $p = Get-SessionRegistryPath -NoCreate
            $dir = Split-Path $p -Parent
            (Test-Path -LiteralPath $dir) | Should -BeFalse
        } finally { Pop-Location }
    }
    It 'Read-SessionRegistry and Read-SessionRegistryRaw never create the state dir on an empty repo' {
        $repo = New-Throwaway 'noc-read'
        Push-Location $repo
        try {
            @(Read-SessionRegistry)    | Should -BeNullOrEmpty
            @(Read-SessionRegistryRaw) | Should -BeNullOrEmpty
            $dir = Join-Path $repo '.agentic-board'
            (Test-Path -LiteralPath $dir) | Should -BeFalse
        } finally { Pop-Location }
    }
    It 'a write still creates the directory exactly as before (only reads are -NoCreate)' {
        $repo = New-Throwaway 'noc-write'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 1 -Branch 'issue-1-x' -WorkPath 'C:/w' -Repo 'o/r' -SessionPid 111 -Via 'pwsh'
            $dir = Join-Path $repo '.agentic-board'
            (Test-Path -LiteralPath $dir) | Should -BeTrue
        } finally { Pop-Location }
    }
}

Describe 'Get-SessionLivePid treats a hostSessionId row as permanently alive (#710 P1)' {
    It 'returns the host-managed sentinel for a row that has a hostSessionId, ignoring sessionPid 0' {
        $s = [pscustomobject]@{ issue = 1; sessionPid = 0; via = 'app'; hostSessionId = 'abc-123' }
        Get-SessionLivePid $s | Should -Be (Get-HostManagedPidMarker)
    }
    It 'falls through to the ordinary pid logic when hostSessionId is empty' {
        $s = [pscustomobject]@{ issue = 1; sessionPid = 0; via = 'app'; hostSessionId = '' }
        Get-SessionLivePid $s | Should -Be 0
    }
    It 'falls through when the row has no hostSessionId property at all (a pre-P1 row)' {
        $s = [pscustomobject]@{ issue = 1; sessionPid = 0; via = 'pwsh' }
        Get-SessionLivePid $s | Should -Be 0
    }
}

Describe 'Read-SessionRegistry keeps a host-managed session alive (real sessions.json)' {
    BeforeAll { $script:Repo = New-Throwaway 'host-alive' }

    It 'a row with a hostSessionId is never pruned even though sessionPid is 0' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 41 -Branch 'issue-41-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'run1'
            Register-HostSession -IssueNum 41 -HostSessionId 'host-99' | Out-Null
            $live = @(Read-SessionRegistry)
        } finally { Pop-Location }
        $row = @($live | Where-Object { [int]$_.issue -eq 41 })
        $row.Count | Should -Be 1
        $row[0].sessionPid | Should -Be (Get-HostManagedPidMarker)
    }
    It 'the SAME row before -RegisterSession (no hostSessionId yet) does not read as live' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 42 -Branch 'issue-42-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'run1'
            $live = @(Read-SessionRegistry | Where-Object { [int]$_.issue -eq 42 })
        } finally { Pop-Location }
        $live.Count | Should -Be 0
    }
}

Describe 'Write-SessionRegistryEntry records and preserves surface/hostSessionId/runId (#710 P1)' {
    BeforeAll { $script:Repo = New-Throwaway 'surface-fields' }

    It 'an app-surface row keeps sessionPid 0 and records surface/runId' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 71 -Branch 'issue-71-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'runXYZ'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 71 })[0]
        } finally { Pop-Location }
        $row.sessionPid | Should -Be 0
        $row.via | Should -Be 'app'
        $row.surface | Should -Be 'app'
        $row.runId | Should -Be 'runXYZ'
        "$($row.hostSessionId)" | Should -Be ''
    }
    It '-RegisterSession-style HostSessionId-only update preserves branch/repo/surface/runId' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 71 -HostSessionId 'host-1'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 71 })[0]
        } finally { Pop-Location }
        $row.branch | Should -Be 'issue-71-x'
        $row.repo   | Should -Be 'o/r'
        $row.surface | Should -Be 'app'
        $row.runId   | Should -Be 'runXYZ'
        $row.hostSessionId | Should -Be 'host-1'
    }
    It 'a plain (non-app) row is unaffected - empty surface/hostSessionId/runId' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 72 -Branch 'issue-72-x' -WorkPath 'C:/w' -Repo 'o/r' -SessionPid 555 -Via 'pwsh'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 72 })[0]
        } finally { Pop-Location }
        "$($row.surface)" | Should -Be ''
        "$($row.hostSessionId)" | Should -Be ''
        "$($row.runId)" | Should -Be ''
    }
}

Describe 'Register-HostSession (#710 P1)' {
    BeforeAll { $script:Repo = New-Throwaway 'register-host' }

    It 'refuses to invent a row for an issue that was never started with -Surface app' {
        Push-Location $script:Repo
        try {
            $r = Register-HostSession -IssueNum 999 -HostSessionId 'x'
            $rows = @(Read-SessionRegistryRaw)
        } finally { Pop-Location }
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'no tiene sesion registrada'
        $rows.Count | Should -Be 0
    }
    It 'records the hostSessionId on an existing row and says which surface' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 5 -Branch 'issue-5-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r1'
            $r = Register-HostSession -IssueNum 5 -HostSessionId 'abc'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 5 })[0]
        } finally { Pop-Location }
        $r.Ok | Should -BeTrue
        $r.Message | Should -Match 'abc'
        $row.hostSessionId | Should -Be 'abc'
    }
    # External review round 1, finding 1: Write-SessionRegistryEntry decides whether to infer a
    # parent-process pid BEFORE it resolves $prev.via inside its lock. Register-HostSession must pass
    # -Via 'app' explicitly, or a host-managed row would silently end up with a REAL launcher pid.
    It 'keeps sessionPid 0 after registering - never infers the launcher/parent pid' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 6 -Branch 'issue-6-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r1'
            Register-HostSession -IssueNum 6 -HostSessionId 'def' | Out-Null
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 6 })[0]
        } finally { Pop-Location }
        $row.sessionPid | Should -Be 0
        $row.via | Should -Be 'app'
    }
    # External review round 1, finding 2: refuse to repurpose a row from a DIFFERENT surface (a
    # normal terminal/wt/pwsh session) as host-managed - Get-SessionLivePid would then report its
    # real, possibly long-dead pid as permanently alive via the sentinel instead.
    It 'refuses to register a hostSessionId on a non-app-surface row' {
        Push-Location $script:Repo
        try {
            Write-SessionRegistryEntry -IssueNum 7 -Branch 'issue-7-x' -WorkPath 'C:/w' -Repo 'o/r' -SessionPid 4242 -Via 'pwsh'
            $r = Register-HostSession -IssueNum 7 -HostSessionId 'nope'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 7 })[0]
        } finally { Pop-Location }
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match "no se arranco con -Surface app"
        "$($row.hostSessionId)" | Should -Be ''
        $row.sessionPid | Should -Be 4242
    }
}

Describe 'New-DispatchManifestEntry (pure)' {
    It 'builds one manifest row with the documented shape' {
        $e = New-DispatchManifestEntry -Issue 12 -Title 'Do the thing' -Repo 'o/r' -Branch 'issue-12-x' `
                                       -Briefing 'briefing text' -OwnedPaths @('a.ps1', 'b.ps1') -RunId 'run1'
        $e.issue | Should -Be 12
        $e.title | Should -Be 'Do the thing'
        $e.repo | Should -Be 'o/r'
        $e.branch | Should -Be 'issue-12-x'
        $e.briefing | Should -Be 'briefing text'
        @($e.ownedPaths) | Should -Be @('a.ps1', 'b.ps1')
        $e.runId | Should -Be 'run1'
    }
    It 'drops null/empty entries from OwnedPaths and defaults to an empty list' {
        $e = New-DispatchManifestEntry -Issue 1 -Repo 'o/r' -Branch 'b' -Briefing 'x' -OwnedPaths @('a', '', $null) -RunId 'r'
        @($e.ownedPaths) | Should -Be @('a')
        $e2 = New-DispatchManifestEntry -Issue 1 -Repo 'o/r' -Branch 'b' -Briefing 'x' -RunId 'r'
        @($e2.ownedPaths).Count | Should -Be 0
    }
}

Describe 'ConvertTo-DispatchManifestJson (pure)' {
    It 'prints "[]" for an empty manifest, not nothing (the piped-empty-array footgun)' {
        ConvertTo-DispatchManifestJson -Entries @() | Should -Be '[]'
        ConvertTo-DispatchManifestJson | Should -Be '[]'
    }
    It 'round-trips a real manifest through ConvertFrom-Json' {
        $e = New-DispatchManifestEntry -Issue 1 -Title 't' -Repo 'o/r' -Branch 'b' -Briefing 'x' -RunId 'r1'
        $json = ConvertTo-DispatchManifestJson -Entries @($e)
        $parsed = @($json | ConvertFrom-Json)
        $parsed.Count | Should -Be 1
        $parsed[0].issue | Should -Be 1
        $parsed[0].runId | Should -Be 'r1'
    }
}

Describe 'Get-IssueOwnedPaths (#710 P1)' {
    It 'returns empty for an issue nobody claimed, and never creates .agentic-board/' {
        $repo = New-Throwaway 'owned-empty'
        Push-Location $repo
        try {
            $paths = @(Get-IssueOwnedPaths -IssueNum 1)
            (Test-Path -LiteralPath (Join-Path $repo '.agentic-board')) | Should -BeFalse
        } finally { Pop-Location }
        $paths.Count | Should -Be 0
    }
    It 'returns the claimed paths recorded by Fleet-Ownership for that issue' {
        $repo = New-Throwaway 'owned-real'
        $stateDir = Join-Path $repo '.agentic-board'
        $fleetDir = Join-Path $stateDir 'fleet'
        New-Item -ItemType Directory -Path $fleetDir -Force | Out-Null
        $claims = @(
            [pscustomobject]@{ issue = 9; branch = 'issue-9-x'; paths = @('scripts/a.ps1', 'scripts/b.ps1'); sessionPid = 0; host = 'H'; ts = '2026-01-01' }
        )
        $claims | ConvertTo-Json -Depth 6 -AsArray | Set-Content -LiteralPath (Join-Path $fleetDir 'ownership.json') -Encoding UTF8
        Push-Location $repo
        try { $paths = @(Get-IssueOwnedPaths -IssueNum 9) } finally { Pop-Location }
        $paths | Should -Be @('scripts/a.ps1', 'scripts/b.ps1')
    }
    It 'reads as empty (never throws) when ownership.json is corrupt' {
        $repo = New-Throwaway 'owned-corrupt'
        $fleetDir = Join-Path (Join-Path $repo '.agentic-board') 'fleet'
        New-Item -ItemType Directory -Path $fleetDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fleetDir 'ownership.json') -Value '{ not json'
        Push-Location $repo
        try { $paths = @(Get-IssueOwnedPaths -IssueNum 9) } finally { Pop-Location }
        $paths.Count | Should -Be 0
    }
}

Describe 'Invoke-IssueStart -SkipWorktree creates no worktree and no session-registry row (#710 P1)' {
    BeforeAll {
        $script:Ctx = [pscustomobject]@{ projectId = 'P'; statusNode = [pscustomobject]@{ id = 'F' }; inProgId = 'O' }
        function New-XItem {
            [pscustomobject]@{
                id = 'ITEM'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content = [pscustomobject]@{
                    __typename = 'Issue'; number = 81; title = 'App surface issue'; state = 'OPEN'; url = 'u'; body = ''
                    labels = [pscustomobject]@{ nodes = @() }
                    assignees = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'o/r' }
                }
            }
        }
    }
    It 'runs board mechanics but never calls New-IssueWorkspace, and leaves workPath empty' {
        $repo = New-Throwaway 'skip-worktree'
        Mock Get-BoardItem { New-XItem }
        Mock Get-IssueBlockers { @() }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @(); revertedAt = $null } }
        Mock Invoke-Gh { $null }
        Mock New-IssueWorkspace { throw 'New-IssueWorkspace must NOT be called on -SkipWorktree' }
        Push-Location $repo
        try {
            $r = Invoke-IssueStart -IssueNum 81 -Ctx $script:Ctx -Owner 'me' -MakeBranch -SkipWorktree
            $rows = @(Read-SessionRegistryRaw)
        } finally { Pop-Location }
        $r.started | Should -BeTrue
        $r.workPath | Should -Be ''
        Should -Invoke New-IssueWorkspace -Times 0
        $rows.Count | Should -Be 0 -Because 'Invoke-IssueStart writes no row itself for -SkipWorktree - the caller does once it knows the runId'
    }
}

Describe 'Get-SessionBriefing -HostManaged (#710 P1)' {
    It 'never says "in this worktree ()" and tells the session the host owns its worktree' {
        $b = Get-SessionBriefing 55 'o/r' 'issue-55-x' '' -HostManaged
        $b | Should -Match 'on branch issue-55-x\.'
        $b | Should -Match 'host application created this session'
        $b | Should -Not -Match '\(\)'
    }
    It 'without -HostManaged, keeps naming the worktree path exactly as before' {
        $b = Get-SessionBriefing 55 'o/r' 'issue-55-x' 'C:/work/issue-55'
        $b | Should -Match 'on branch issue-55-x in this worktree \(C:/work/issue-55\)'
    }
}

Describe '-Stop / -Relaunch refuse a host-managed session on the real script (external review round 1, finding 3)' {
    # Both modes sit BEFORE the GH_TOKEN check (local-only, no network) - a fake -TokenVar never
    # gets reached, same as the -RecordPr-on-the-real-script test in Board-Work.CrossRepo.Tests.ps1.
    It '-Stop never hands the host-managed pid sentinel to Stop-ProcessTree' {
        $repo = New-Throwaway 'stop-host'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 61 -Branch 'issue-61-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r1'
            Register-HostSession -IssueNum 61 -HostSessionId 'stop-host-id' | Out-Null
            $out = pwsh -NoProfile -File $script:Script -Stop 61 -Force -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
        } finally { Pop-Location }
        $out | Should -Match 'host-managed'
        $out | Should -Not -Match 'PID 1\b'
    }
    It '-Relaunch never tries to kill or relaunch a host-managed session' {
        $repo = New-Throwaway 'relaunch-host'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 62 -Branch 'issue-62-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r1'
            Register-HostSession -IssueNum 62 -HostSessionId 'relaunch-host-id' | Out-Null
            $out = pwsh -NoProfile -File $script:Script -Relaunch 62 -Force -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 62 })[0]
        } finally { Pop-Location }
        $out | Should -Match 'host-managed'
        $row.hostSessionId | Should -Be 'relaunch-host-id' -Because 'a refused relaunch must leave the registry row untouched'
    }
    It '-Stop on an ordinary (non-host-managed) session is unaffected - still previews the real pid' {
        $repo = New-Throwaway 'stop-plain'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 63 -Branch 'issue-63-x' -WorkPath $repo -Repo 'o/r' -SessionPid $PID -Via 'pwsh'
            $out = pwsh -NoProfile -File $script:Script -Stop 63 -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 2>&1 | Out-String
        } finally { Pop-Location }
        $out | Should -Not -Match 'host-managed'
    }
}

# ===========================================================================================
# External review, ROUND 2 (Codex gpt-5.5 + Antigravity gemini-3.1-pro, independently).
# Three defects, each MEASURED on this machine before it was accepted - see each Describe.
# (A fourth finding, "ConvertTo-Json -AsArray breaks Windows PowerShell 5.1", was REJECTED:
#  -AsArray is already used in ten shipped scripts, every entry point in this plugin launches
#  `pwsh` (7.x), and the repo's only 5.1 concern is PARSE-time encoding - ScriptEncoding.Tests.ps1.
#  Both reviewers raised it because the review prompt wrongly asserted 5.1 was a runtime target.)
# ===========================================================================================

Describe 'Invoke-WithSessionRegistryLock survives a holder that DIES while another waits (review round 2)' {
    # MEASURED, not reasoned: when a process dies holding a named mutex AND another process is
    # already waiting on it, the waiter's WaitOne raises AbandonedMutexException - and .NET hands
    # that waiter OWNERSHIP anyway. Uncaught, $owns stays $false, the body never runs, the finally
    # disposes an owned mutex (abandoning it again) and the whole call throws.
    #
    # The waiter must already hold a handle for this to happen at all: if NO handle survives the
    # holder's death the kernel object is destroyed and the next caller creates a brand-new mutex
    # with no abandonment to report (measured too - that is why the naive version of this test
    # passed against the unfixed code and proved nothing). Hence the real two-process race below.
    It 'runs the body and returns normally when the previous holder was killed mid-write' {
        $repo = New-Throwaway 'lock-abandon'
        $flag = Join-Path $TestDrive ('holding-' + [guid]::NewGuid().ToString('N') + '.flag')
        $holderPath = Join-Path $TestDrive 'surface-lock-holder.ps1'
        @'
param([string]$RepoPath, [string]$ScriptPath, [string]$Flag)
Set-Location -LiteralPath $RepoPath
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
. $ScriptPath
$env:ABIOS_BOARDWORK_DOTSOURCE = ''
$p = Get-SessionRegistryPath
Invoke-WithSessionRegistryLock -Path $p -Body {
    Set-Content -LiteralPath $Flag -Value 'held'
    Start-Sleep -Milliseconds 2500
    [Environment]::Exit(1)   # muere SIN soltar el mutex, con el otro proceso ya esperando
}
'@ | Set-Content -LiteralPath $holderPath -Encoding UTF8

        Push-Location $repo
        try {
            $p = Get-SessionRegistryPath
            $holder = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-File', $holderPath, '-RepoPath', $repo, '-ScriptPath', "$script:Script", '-Flag', $flag)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $flag) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 50 }
            (Test-Path -LiteralPath $flag) | Should -BeTrue -Because 'the holder process must have taken the lock before we start waiting'

            # Entramos a esperar MIENTRAS el otro lo tiene: moriremos dentro de su ventana.
            $result = Invoke-WithSessionRegistryLock -Path $p -TimeoutMs 20000 -Body { 'cuerpo-ejecutado' }
            $result | Should -Be 'cuerpo-ejecutado' -Because 'an abandoned mutex hands us ownership: the body must still run'
            $holder.WaitForExit(20000) | Out-Null

            # Y el candado queda USABLE despues: si el finally hubiera soltado mal, esto colgaria.
            Invoke-WithSessionRegistryLock -Path $p -TimeoutMs 10000 -Body { 'segunda' } | Should -Be 'segunda'
        } finally { Pop-Location }
    }
}

Describe 'Write-SessionRegistryEntry -UpdateOnly never invents a row (review round 2)' {
    # Register-HostSession validated the row OUTSIDE the lock and then called a writer that appends
    # unconditionally. If the row vanished in between (auto-clean, -Stop, another fleet process),
    # the append wrote a GHOST row: empty repo/branch/workPath, sessionPid 0 and a hostSessionId -
    # which Get-SessionLivePid then reports as permanently alive by the sentinel. -UpdateOnly closes
    # the window inside the lock, so no ordering of the race can create one.
    It 'writes nothing at all when the issue has no row' {
        $repo = New-Throwaway 'updateonly-empty'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 77 -Via 'app' -HostSessionId 'ghost' -UpdateOnly
            @(Read-SessionRegistryRaw).Count | Should -Be 0 -Because '-UpdateOnly must never create a row'
        } finally { Pop-Location }
    }
    It 'still updates a row that DOES exist' {
        $repo = New-Throwaway 'updateonly-present'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 78 -Branch 'issue-78-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r9'
            Write-SessionRegistryEntry -IssueNum 78 -Via 'app' -HostSessionId 'real-id' -UpdateOnly
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 78 })[0]
            $row.hostSessionId | Should -Be 'real-id'
            $row.branch        | Should -Be 'issue-78-x' -Because 'an update must preserve the fields it was not given'
            $row.surface       | Should -Be 'app'
        } finally { Pop-Location }
    }
    It 'Register-HostSession uses it - a row deleted after the check leaves no ghost behind' {
        $repo = New-Throwaway 'register-ghost'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 79 -Branch 'issue-79-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'r9'
            @(Read-SessionRegistryRaw).Count | Should -Be 1
            $r = Register-HostSession -IssueNum 79 -HostSessionId 'id-79'
            $r.Ok | Should -BeTrue
            @(Read-SessionRegistryRaw).Count | Should -Be 1 -Because 'registering must update the row, never append a second one'
        } finally { Pop-Location }
    }
}

Describe '-Surface app -Json prints a manifest a consumer can actually parse (review round 2)' -Tag 'Wired' {
    # MEASURED: `pwsh -File script.ps1 -Json > out.txt` from an external shell captures Write-Host
    # too - the host writes the information stream to the process's stdout handle, and a native
    # redirect takes the handle, not PowerShell's stream 1. So every batch header and status line
    # landed in front of the "raw JSON" this flag advertises, and ConvertFrom-Json on it fails.
    # The whole point of -Surface app is that an AGENT hands the manifest to the host's spawn tool.
    BeforeAll {
        $script:FakeJ = Join-Path $TestDrive 'fakegh-json'
        New-Item -ItemType Directory -Path $script:FakeJ -Force | Out-Null
        @'
$a = @($args); $line = $a -join ' '
function Out-Json($o) { $o | ConvertTo-Json -Depth 10 -Compress }
if ($line -match '^project field-list') {
    Out-Json ([pscustomobject]@{ fields = @([pscustomobject]@{ id = 'FSTATUS'; name = 'Status'; type = 'ProjectV2SingleSelectField'
        options = @([pscustomobject]@{ id = 'OPTBACK'; name = 'Backlog' }, [pscustomobject]@{ id = 'OPTPROG'; name = 'In Progress' }) }) })
    exit 0
}
if ($line -match '^project view') { Out-Json ([pscustomobject]@{ id = 'PROJ1'; number = 13; title = 'board' }); exit 0 }
if ($line -match '^project item-list') {
    Out-Json ([pscustomobject]@{ totalCount = 1; items = @([pscustomobject]@{ id = 'i1'; title = 'app surface issue'
        status = 'Backlog'; labels = @(); content = [pscustomobject]@{ type = 'Issue'; number = 900; title = 'app surface issue'; repository = 'o/r' } }) })
    exit 0
}
if ($line -match '^pr list')    { Write-Output '[]'; exit 0 }
if ($line -match '^issue view') { Out-Json ([pscustomobject]@{ number = 900; title = 'app surface issue'; state = 'OPEN'; body = ''; url = 'u'; labels = @(); assignees = @() }); exit 0 }
if ($line -match 'node\(id:') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ node = [pscustomobject]@{
        items = [pscustomobject]@{ pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }
            nodes = @([pscustomobject]@{ id = 'ITEM1'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content = [pscustomobject]@{ __typename = 'Issue'; number = 900; title = 'app surface issue'; state = 'OPEN'; url = 'u'; body = ''
                    labels = [pscustomobject]@{ nodes = @() }; assignees = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'o/r' } } }) } } } })
    exit 0
}
if ($line -match 'projectV2') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ user = [pscustomobject]@{ projectV2 = [pscustomobject]@{
        id = 'PROJ1'
        fields = [pscustomobject]@{ nodes = @([pscustomobject]@{ id = 'FSTATUS'; name = 'Status'
            options = @([pscustomobject]@{ id = 'OPTBACK'; name = 'Backlog' }, [pscustomobject]@{ id = 'OPTPROG'; name = 'In Progress' }) }) }
        items = [pscustomobject]@{ pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }
            nodes = @([pscustomobject]@{ id = 'ITEM1'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content = [pscustomobject]@{ __typename = 'Issue'; number = 900; title = 'app surface issue'; state = 'OPEN'; url = 'u'; body = ''
                    labels = [pscustomobject]@{ nodes = @() }; assignees = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'o/r' } } }) } } } } })
    exit 0
}
if ($line -match 'graphql') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{
        issue = [pscustomobject]@{ number = 900; title = 'app surface issue'; state = 'OPEN'; url = 'u'; body = ''
            labels = [pscustomobject]@{ nodes = @() }; assignees = [pscustomobject]@{ nodes = @() }
            repository = [pscustomobject]@{ nameWithOwner = 'o/r' }
            timelineItems = [pscustomobject]@{ nodes = @() } }
        issues = [pscustomobject]@{ pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }; nodes = @() }
        pullRequests = [pscustomobject]@{ pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }; nodes = @() } } } })
    exit 0
}
# Cualquier otra llamada: SILENCIO en stdout (solo stderr), para no contaminar el JSON del manifiesto.
[Console]::Error.WriteLine("fakegh: unexpected call: $line"); Write-Output '{}'; exit 0
'@ | Set-Content -LiteralPath (Join-Path $script:FakeJ 'gh.ps1') -Encoding UTF8

        $script:RepoJ = Join-Path $TestDrive 'json-purity'
        New-Item -ItemType Directory -Path $script:RepoJ -Force | Out-Null
        Push-Location $script:RepoJ
        git init -q -b main 2>&1 | Out-Null
        git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
        git remote add origin https://github.com/o/r.git
        Set-Content -LiteralPath README.md -Value 'x'
        git add README.md; git commit -q -m 'chore: first' 2>&1 | Out-Null
        Pop-Location
    }

    It 'stdout is valid JSON, with no human output in front of it' {
        $outFile = Join-Path $TestDrive 'manifest.out'
        $errFile = Join-Path $TestDrive 'manifest.err'
        $savedPath = $env:PATH; $savedTok = $env:GH_TOKEN
        $env:PATH = "$($script:FakeJ)$([IO.Path]::PathSeparator)$savedPath"
        $env:GH_TOKEN = 'fake-token'
        try {
            Push-Location $script:RepoJ
            Start-Process -FilePath 'pwsh' -WindowStyle Hidden -Wait -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ArgumentList @('-NoProfile', '-File', "$script:Script", '-Parallel', '900', '-Surface', 'app', '-Json', '-DryRun', '-ProjectNum', '13', '-Owner', 'o')
            Pop-Location
        } finally { $env:PATH = $savedPath; $env:GH_TOKEN = $savedTok }

        $raw = (Get-Content -LiteralPath $outFile -Raw)
        $raw | Should -Not -BeNullOrEmpty -Because "the manifest must reach stdout. stderr was: $(Get-Content -LiteralPath $errFile -Raw)"
        { $raw | ConvertFrom-Json } | Should -Not -Throw -Because "stdout must be raw JSON, but it was:`n$raw"
        $manifest = @($raw | ConvertFrom-Json)
        @($manifest).Count | Should -BeGreaterThan 0 -Because 'a vacuous empty manifest would make this test prove nothing'
        [int]$manifest[0].issue | Should -Be 900
        $manifest[0].runId     | Should -Not -BeNullOrEmpty
    }
}

Describe 'A later NON-app session never inherits host-managed metadata (review round 3)' {
    # Write-SessionRegistryEntry carries surface/runId/hostSessionId forward from the previous row
    # whenever the caller omits them - which is right for an app row being updated, and wrong for a
    # later ORDINARY start of the same issue. Without this, restarting issue #N in a terminal after
    # it once ran on -Surface app produced a row that claimed a stale hostSessionId: Get-SessionLivePid
    # then reports the host-managed sentinel, so the new local session reads as alive FOREVER and
    # -Stop / -Relaunch refuse to manage it (they are built to refuse host-managed rows).
    It 'clears surface/hostSessionId/runId when the same issue is restarted in a terminal' {
        $repo = New-Throwaway 'no-inherit-host'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 91 -Branch 'issue-91-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'run-1'
            Register-HostSession -IssueNum 91 -HostSessionId 'host-91' | Out-Null
            $before = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 91 })[0]
            $before.hostSessionId | Should -Be 'host-91' -Because 'precondition: the app row is host-managed'

            # Un arranque normal posterior del MISMO issue (worktree local, pid real).
            Write-SessionRegistryEntry -IssueNum 91 -Branch 'issue-91-x' -WorkPath $repo -Repo 'o/r' -SessionPid $PID -Via 'pwsh'
            $after = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 91 })[0]

            $after.hostSessionId | Should -BeNullOrEmpty -Because 'a terminal session has a real pid and is not host-managed'
            $after.surface       | Should -BeNullOrEmpty
            $after.runId         | Should -BeNullOrEmpty
            Get-SessionLivePid $after | Should -Not -Be (Get-HostManagedPidMarker) -Because 'it must resolve by its REAL pid, not the host-managed sentinel'
        } finally { Pop-Location }
    }
    It 'still preserves them across an app-surface update (the case the carry-forward exists for)' {
        $repo = New-Throwaway 'inherit-app'
        Push-Location $repo
        try {
            Write-SessionRegistryEntry -IssueNum 92 -Branch 'issue-92-x' -Repo 'o/r' -Via 'app' -Surface 'app' -RunId 'run-2'
            Register-HostSession -IssueNum 92 -HostSessionId 'host-92' | Out-Null
            # Una escritura posterior SIN -Via explicito hereda via='app' del prev: sigue siendo app.
            Write-SessionRegistryEntry -IssueNum 92 -Branch 'issue-92-x' -Repo 'o/r'
            $row = @(Read-SessionRegistryRaw | Where-Object { [int]$_.issue -eq 92 })[0]
            $row.hostSessionId | Should -Be 'host-92'
            $row.surface       | Should -Be 'app'
            $row.runId         | Should -Be 'run-2'
        } finally { Pop-Location }
    }
}

Describe '-Surface app -Json reports failures instead of hiding them (review round 3)' -Tag 'Wired' {
    # The first version of the Write-Host shadow SWALLOWED output. Invoke-BatchIssueStart reports a
    # failed start with Write-Host, so "issue #N could not start" became nothing at all: no message
    # on any stream, the issue quietly absent from the manifest, exit code 0. A machine consumer had
    # no way to tell a wave that fully dispatched from one that dispatched nothing.
    It 'sends the human lines to stderr, keeps stdout pure JSON, and exits non-zero when nothing dispatched' {
        $fake = Join-Path $TestDrive 'fakegh-fail'
        New-Item -ItemType Directory -Path $fake -Force | Out-Null
        # Un board valido, pero el issue pedido NO esta en el: todo se salta -> manifiesto vacio.
        $ghFail = @'
$a = @($args); $line = $a -join ' '
function Out-Json($o) { $o | ConvertTo-Json -Depth 10 -Compress }
if ($line -match 'node\(id:') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ node = [pscustomobject]@{
        items = [pscustomobject]@{ pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = '' }; nodes = @() } } } })
    exit 0
}
if ($line -match 'projectV2') {
    Out-Json ([pscustomobject]@{ data = [pscustomobject]@{ user = [pscustomobject]@{ projectV2 = [pscustomobject]@{
        id = 'PROJ1'
        fields = [pscustomobject]@{ nodes = @([pscustomobject]@{ id = 'FSTATUS'; name = 'Status'
            options = @([pscustomobject]@{ id = 'OPTBACK'; name = 'Backlog' }, [pscustomobject]@{ id = 'OPTPROG'; name = 'In Progress' }) }) } } } } })
    exit 0
}
if ($line -match '^pr list') { Write-Output '[]'; exit 0 }
[Console]::Error.WriteLine("fakegh: unexpected call: $line"); Write-Output '{}'; exit 0
'@
        Set-Content -LiteralPath (Join-Path $fake 'gh.ps1') -Value $ghFail -Encoding UTF8

        $repo = Join-Path $TestDrive 'json-fail'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        git init -q -b main 2>&1 | Out-Null
        git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
        git remote add origin https://github.com/o/r.git
        Set-Content -LiteralPath README.md -Value 'x'; git add README.md; git commit -q -m 'chore: first' 2>&1 | Out-Null
        Pop-Location

        $outFile = Join-Path $TestDrive 'fail.out'; $errFile = Join-Path $TestDrive 'fail.err'
        $savedPath = $env:PATH; $savedTok = $env:GH_TOKEN
        $env:PATH = "$fake$([IO.Path]::PathSeparator)$savedPath"; $env:GH_TOKEN = 'fake-token'
        try {
            Push-Location $repo
            $p = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -ArgumentList @('-NoProfile', '-File', "$script:Script", '-Parallel', '901', '-Surface', 'app', '-Json', '-DryRun', '-ProjectNum', '13', '-Owner', 'o')
            Pop-Location
        } finally { $env:PATH = $savedPath; $env:GH_TOKEN = $savedTok }

        $out = (Get-Content -LiteralPath $outFile -Raw)
        $err = (Get-Content -LiteralPath $errFile -Raw)
        { $out | ConvertFrom-Json } | Should -Not -Throw -Because "stdout must stay pure JSON, but it was:`n$out"
        @($out | ConvertFrom-Json).Count | Should -Be 0 -Because 'no issue could start, so the manifest is empty'
        $err | Should -Match 'SKIP' -Because "the reason must reach SOME stream. stderr was:`n$err"
        $p.ExitCode | Should -Not -Be 0 -Because 'a run that dispatched nothing is a failure, not an empty success'
    }
}
