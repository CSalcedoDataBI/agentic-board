#Requires -Modules Pester
<#  Pester tests for the fail-closed run-ledger checkpoint (#771, fixes #730).

    Two layers:
      1. RunLedgerCheckpoint.ps1 on its own - no-op without an active run, appends a checkpoint
         when one is active, and THROWS (writing nothing) when the checkpoint cannot be written.
      2. The side-effecting steps of Board-Work.ps1 that call it - the checkpoint lands BEFORE the
         first GitHub write, a failing checkpoint stops the step, and with no ledger the step runs
         exactly as before. gh is mocked throughout (Invoke-Gh); nothing touches the network. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    . (Join-Path $script:Scripts 'RunLedgerCheckpoint.ps1')

    $script:T0 = [datetime]'2026-10-02T10:00:00Z'

    # A fresh state dir under $TestDrive, optionally holding an active-run.json marker.
    function New-StateDir([string]$Name, [string]$Status = '', [object[]]$Checkpoints = $null) {
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($Status) {
            $m = [ordered]@{ epic = 348; board = 13; repo = 'o/r'; status = $Status
                             started = '2026-10-02T09:00:00Z'; updated = '2026-10-02T09:00:00Z'
                             queue = @(349, 350); entries = @() }
            if ($null -ne $Checkpoints) { $m.checkpoints = $Checkpoints }
            ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dir 'active-run.json') -Encoding utf8
        }
        return $dir
    }
    function Read-Marker([string]$Dir) { Get-Content -LiteralPath (Join-Path $Dir 'active-run.json') -Raw | ConvertFrom-Json }
}

Describe 'Write-RunLedgerCheckpoint - no active run is a strict no-op' {
    It 'returns $null and creates nothing when there is no marker' {
        $dir = New-StateDir 'none'
        Write-RunLedgerCheckpoint -Step 'start' -Issue 1 -StateDir $dir | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $dir 'active-run.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0
    }
    It 'returns $null and leaves a CLOSED run byte-for-byte untouched' {
        $dir = New-StateDir 'closed' -Status 'closed'
        $before = Get-Content -LiteralPath (Join-Path $dir 'active-run.json') -Raw
        Write-RunLedgerCheckpoint -Step 'start' -Issue 1 -StateDir $dir | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $dir 'active-run.json') -Raw | Should -BeExactly $before
    }
    It 'does not even call the writer when no run is active' {
        Mock Save-RunLedgerMarker { throw 'must not be called' }
        $dir = New-StateDir 'none2'
        { Write-RunLedgerCheckpoint -Step 'start' -StateDir $dir } | Should -Not -Throw
        Should -Invoke Save-RunLedgerMarker -Times 0 -Exactly
    }
}

Describe 'Write-RunLedgerCheckpoint - active run' {
    It 'appends the step to the marker and keeps every other field' {
        $dir = New-StateDir 'active' -Status 'active'
        $cp = Write-RunLedgerCheckpoint -Step 'start' -Issue 349 -Detail 'issue-349-x' -StateDir $dir -When $script:T0
        $cp.step  | Should -BeExactly 'start'
        $cp.issue | Should -Be 349
        $cp.at    | Should -BeExactly '2026-10-02T10:00:00Z'
        $m = Read-Marker $dir
        $m.epic   | Should -Be 348
        $m.status | Should -BeExactly 'active'
        @($m.queue).Count | Should -Be 2
        @($m.checkpoints).Count | Should -Be 1
        $m.checkpoints[0].step   | Should -BeExactly 'start'
        $m.checkpoints[0].detail | Should -BeExactly 'issue-349-x'
        # Raw text: ConvertFrom-Json would turn the stamp into a DateTime on the way back in.
        Get-Content -LiteralPath (Join-Path $dir 'active-run.json') -Raw | Should -Match '"updated":\s*"2026-10-02T10:00:00Z"'
    }
    It 'appends to an existing trail and caps it, keeping the newest' {
        $old = 1..60 | ForEach-Object { [ordered]@{ step = 'start'; issue = $_; detail = ''; at = '2026-10-01T00:00:00Z' } }
        $dir = New-StateDir 'capped' -Status 'active' -Checkpoints $old
        $null = Write-RunLedgerCheckpoint -Step 'launch' -Issue 999 -StateDir $dir -When $script:T0
        $m = Read-Marker $dir
        @($m.checkpoints).Count | Should -Be 50
        $m.checkpoints[-1].issue | Should -Be 999
        $m.checkpoints[-1].step  | Should -BeExactly 'launch'
    }
    It 'leaves no temp file behind after a successful write' {
        $dir = New-StateDir 'notmp' -Status 'active'
        $null = Write-RunLedgerCheckpoint -Step 'start' -StateDir $dir
        @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -Force).Count | Should -Be 0
    }
}

Describe 'Write-RunLedgerCheckpoint - fails closed' {
    It 'THROWS when the writer fails, and the marker is left as it was' {
        $dir = New-StateDir 'writerfail' -Status 'active'
        $before = Get-Content -LiteralPath (Join-Path $dir 'active-run.json') -Raw
        Mock Save-RunLedgerMarker { throw 'disk full' }
        { Write-RunLedgerCheckpoint -Step 'start' -Issue 7 -StateDir $dir } |
            Should -Throw -ExpectedMessage "*checkpoint failed before 'start' on #7*disk full*Refusing*"
        Get-Content -LiteralPath (Join-Path $dir 'active-run.json') -Raw | Should -BeExactly $before
    }
    It 'THROWS on a real write failure (the temp path is blocked by a directory)' {
        $dir = New-StateDir 'blocked' -Status 'active'
        New-Item -ItemType Directory -Path (Join-Path $dir "active-run.json.$PID.tmp") | Out-Null
        { Write-RunLedgerCheckpoint -Step 'launch' -Issue 3 -StateDir $dir } | Should -Throw -ExpectedMessage '*could not write*'
        (Read-Marker $dir).PSObject.Properties['checkpoints'] | Should -BeNullOrEmpty
    }
    It 'THROWS on a read-only marker (Windows: the rename cannot replace it)' -Skip:(-not $IsWindows) {
        $dir = New-StateDir 'readonly' -Status 'active'
        $f = Get-Item -LiteralPath (Join-Path $dir 'active-run.json')
        $f.IsReadOnly = $true
        try {
            { Write-RunLedgerCheckpoint -Step 'start' -Issue 4 -StateDir $dir } | Should -Throw -ExpectedMessage '*Refusing*'
        } finally { $f.IsReadOnly = $false }
        @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -Force).Count | Should -Be 0
    }
    It 'THROWS when the marker exists but is unreadable JSON (a run may be active)' {
        $dir = New-StateDir 'corrupt'
        Set-Content -LiteralPath (Join-Path $dir 'active-run.json') -Value '{ not json'
        { Write-RunLedgerCheckpoint -Step 'start' -StateDir $dir } | Should -Throw -ExpectedMessage '*unreadable*'
    }
}

Describe 'Board-Work side-effecting steps checkpoint first (#771)' {
    BeforeAll {
        $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Board-Work.ps1')
        $env:ABIOS_BOARDWORK_DOTSOURCE = ''

        $script:Ctx = [pscustomobject]@{ projectId = 'PROJ'; statusNode = [pscustomobject]@{ id = 'FIELD' }; inProgId = 'OPT' }
        function New-FakeItem {
            [pscustomobject]@{
                id          = 'ITEM'
                fieldValues = [pscustomobject]@{ nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = 'Status' }; name = 'Backlog' }) }
                content     = [pscustomobject]@{
                    __typename = 'Issue'; number = 5; title = 'Do a thing'; state = 'OPEN'; url = 'u'; body = ''
                    assignees  = [pscustomobject]@{ nodes = @() }
                    labels     = [pscustomobject]@{ nodes = @() }
                    repository = [pscustomobject]@{ nameWithOwner = 'owner/repo' }
                }
            }
        }
    }
    BeforeEach {
        Mock Get-BoardItem       { New-FakeItem }
        Mock Get-IssueBlockers   { @() }
        Mock Get-LastClaim       { '' }
        Mock Get-IssueLinkedWork { [pscustomobject]@{ prs = @(); commits = @() } }
        $script:GhCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-Gh {
            # Record, for every gh write, how many checkpoints the marker already held at that moment.
            $p = Join-Path $script:State 'active-run.json'
            $n = if (Test-Path -LiteralPath $p) { @((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).checkpoints | Where-Object { $_ }).Count } else { -1 }
            $script:GhCalls.Add([pscustomobject]@{ what = $What; checkpointsSeen = $n })
            $null
        }
    }

    It 'Invoke-IssueStart writes the checkpoint BEFORE the first gh write' {
        $script:State = New-StateDir 'bw-active' -Status 'active'
        Mock Get-AbiosStateDir { $script:State }
        $r = Invoke-IssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeTrue
        $script:GhCalls.Count | Should -BeGreaterThan 0
        $script:GhCalls[0].what | Should -Match 'In Progress'
        $script:GhCalls[0].checkpointsSeen | Should -Be 1
        $m = Read-Marker $script:State
        $m.checkpoints[0].step  | Should -BeExactly 'start'
        $m.checkpoints[0].issue | Should -Be 5
    }

    It 'a failing checkpoint stops Invoke-IssueStart before ANY gh write' {
        $script:State = New-StateDir 'bw-fail' -Status 'active'
        Mock Get-AbiosStateDir { $script:State }
        Mock Save-RunLedgerMarker { throw 'ledger locked' }
        { Invoke-IssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me' } | Should -Throw -ExpectedMessage '*ledger locked*'
        Should -Invoke Invoke-Gh -Times 0 -Exactly
    }

    It 'in a -Parallel batch the failing checkpoint becomes that issue''s skip, not a crash' {
        $script:State = New-StateDir 'bw-batch' -Status 'active'
        Mock Get-AbiosStateDir { $script:State }
        Mock Save-RunLedgerMarker { throw 'ledger locked' }
        $r = Invoke-BatchIssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeFalse
        $r.skipped | Should -Match 'checkpoint failed'
        Should -Invoke Invoke-Gh -Times 0 -Exactly
    }

    It 'with NO ledger the start runs exactly as before and no marker is created' {
        $script:State = New-StateDir 'bw-none'
        Mock Get-AbiosStateDir { $script:State }
        Mock Save-RunLedgerMarker { throw 'must not be called' }
        $r = Invoke-IssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me'
        $r.started | Should -BeTrue
        @($script:GhCalls | Where-Object { $_.what -match 'In Progress' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:State 'active-run.json') | Should -BeFalse
        Should -Invoke Save-RunLedgerMarker -Times 0 -Exactly
    }

    It 'a dry-run start never checkpoints (it changes nothing)' {
        $script:State = New-StateDir 'bw-dry' -Status 'active'
        Mock Get-AbiosStateDir { $script:State }
        $null = Invoke-IssueStart -IssueNum 5 -Ctx $script:Ctx -Owner 'me' -DryRunStart
        (Read-Marker $script:State).PSObject.Properties['checkpoints'] | Should -BeNullOrEmpty
    }

    Context 'Start-WorktreeSession (launching a session)' {
        BeforeEach {
            $script:Work = Join-Path $TestDrive ("work-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:Work | Out-Null
            Mock Get-AbiosDir { $script:State }
            Mock Start-Process { $null }
        }
        It 'checkpoints the launch, then spawns' {
            $script:State = New-StateDir 'launch-ok' -Status 'active'
            Mock Get-AbiosStateDir { $script:State }
            $null = Start-WorktreeSession -IssueNum 9 -Repo 'owner/repo' -Branch 'issue-9-x' -WorkPath $script:Work
            Should -Invoke Start-Process -Times 1 -Exactly
            $m = Read-Marker $script:State
            $m.checkpoints[-1].step  | Should -BeExactly 'launch'
            $m.checkpoints[-1].issue | Should -Be 9
        }
        It 'a failing checkpoint launches nothing and returns $null' {
            $script:State = New-StateDir 'launch-fail' -Status 'active'
            Mock Get-AbiosStateDir { $script:State }
            Mock Save-RunLedgerMarker { throw 'ledger locked' }
            Start-WorktreeSession -IssueNum 9 -Repo 'owner/repo' -Branch 'issue-9-x' -WorkPath $script:Work | Should -BeNullOrEmpty
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}
