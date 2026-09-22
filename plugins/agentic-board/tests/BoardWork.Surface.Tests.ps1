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
