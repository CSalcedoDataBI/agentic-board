#Requires -Modules Pester
<#  Recurrence matching in Invoke-FieldScan (#476): "recurrence counts for already-filed defects".

    The epic asked for the sweep to distinguish three things: NEW defects, RECURRENCE of defects
    already filed, and sessions where the tool was never used. The first and third existed; nothing
    correlated an episode with an issue, so a script failing for the 30th time looked exactly like
    one failing for the first.

    These tests run the REAL script (a `pwsh -File` child) over a synthetic transcript store, with the
    filed issues supplied through -CandidatesFile - the offline path, so no GitHub, no token.  #>

BeforeAll {
    $script:Scan = Join-Path $PSScriptRoot '..' 'scripts' 'Invoke-FieldScan.ps1' | Resolve-Path
    $script:Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ('fs-rec-' + [guid]::NewGuid().ToString('N'))
    $script:Proj = Join-Path $script:Tmp 'projects'
    $script:Field = Join-Path $script:Tmp 'field'
    New-Item -ItemType Directory -Path (Join-Path $script:Proj 'projA') -Force | Out-Null

    function script:ToolUse([string]$Id, [string]$Cmd, [string]$Ts) {
        (@{ type = 'assistant'; timestamp = $Ts; message = @{ content = @(@{ type = 'tool_use'; id = $Id; input = @{ command = $Cmd } }) } } | ConvertTo-Json -Depth 8 -Compress)
    }
    function script:ToolErr([string]$Id, [string]$Ts) {
        (@{ type = 'user'; timestamp = $Ts; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = $Id; is_error = $true }) } } | ConvertTo-Json -Depth 8 -Compress)
    }
    function script:ToolOk([string]$Id, [string]$Ts) {
        (@{ type = 'user'; timestamp = $Ts; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = $Id; is_error = $false }) } } | ConvertTo-Json -Depth 8 -Compress)
    }

    # Board-Plan.ps1 fails twice in a row (a failure AND a repetition); Backup-Board.ps1 fails once.
    $planCmd   = 'pwsh -File C:\Users\x\.claude\plugins\cache\agentic-board\scripts\Board-Plan.ps1 -Epic 5'
    $backupCmd = 'pwsh -File C:\Users\x\.claude\plugins\cache\agentic-board\scripts\Backup-Board.ps1'
    $fillCmd   = 'pwsh -File C:\Users\x\.claude\plugins\cache\agentic-board\scripts\Board-Fill.ps1'
    $lines = @(
        (ToolUse 't1' $planCmd   '2026-09-01T10:00:00Z'), (ToolErr 't1' '2026-09-01T10:00:02Z'),
        (ToolUse 't2' $planCmd   '2026-09-01T10:00:10Z'), (ToolErr 't2' '2026-09-01T10:00:12Z'),
        (ToolUse 't3' $backupCmd '2026-09-01T10:05:00Z'), (ToolErr 't3' '2026-09-01T10:05:02Z'),
        # Board-Fill.ps1 SUCCEEDS twice in a row: a repetition signal with no failure at all.
        (ToolUse 't4' $fillCmd   '2026-09-01T10:10:00Z'), (ToolOk 't4' '2026-09-01T10:10:02Z'),
        (ToolUse 't5' $fillCmd   '2026-09-01T10:10:05Z'), (ToolOk 't5' '2026-09-01T10:10:07Z')
    )
    Set-Content -LiteralPath (Join-Path $script:Proj 'projA' 'sess1.jsonl') -Value $lines -Encoding UTF8

    $script:Cands = Join-Path $script:Tmp 'filed.json'
    @(
        @{ number = 10; title = 'Board-Plan.ps1 loses its cursor on boards over 100 items'; body = ''; url = 'u10'; state = 'OPEN'; stateReason = '' },
        @{ number = 11; title = 'Board-Plan fails when the epic has no sub-issues'; body = ''; url = 'u11'; state = 'CLOSED'; stateReason = 'COMPLETED' },
        @{ number = 12; title = 'Board-Work -Start ignores the Todo status'; body = 'unrelated'; url = 'u12'; state = 'OPEN'; stateReason = '' }
    ) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:Cands -Encoding UTF8

    function script:Invoke-Scan {
        param([string[]]$Extra = @())
        # a fresh field root per run so the ledger from a previous run cannot hide the sessions
        $fr = Join-Path $script:Tmp ('field-' + [guid]::NewGuid().ToString('N'))
        $out = & pwsh -NoProfile -File $script:Scan -FieldRoot $fr -ProjectsRoot $script:Proj -Json @Extra 2>&1
        [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out | Out-String); FieldRoot = $fr }
    }
    function script:ScanJson($r) {
        # -Json emits one JSON document; warnings may precede it, so parse from the first '{'.
        $i = $r.Text.IndexOf('{')
        $r.Text.Substring($i) | ConvertFrom-Json
    }
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-FieldScan honours -FieldRoot and -ProjectsRoot (found while testing #476)' {
    It 'reads the transcript root it was GIVEN and writes its ledger under the field root it was given' {
        # Both files it dot-sources declare these parameters; their param() blocks reset them in the
        # caller's scope, so the sweep used to read AND write the user's real store whatever was passed.
        $r = Invoke-Scan
        $j = ScanJson $r
        $j.ledger  | Should -BeLike "$($r.FieldRoot)*"
        $j.records | Should -BeLike "$($r.FieldRoot)*"
        $j.scanned | Should -Be 1 -Because 'the synthetic store holds exactly one session'
        Test-Path -LiteralPath (Join-Path $r.FieldRoot 'ledger.csv') | Should -BeTrue
    }
}

Describe 'Invoke-FieldScan keeps -Window and -Json after loading its helpers' {
    It '-Window 1 is honoured: a repetition seen with the default window is not seen with a window of 1' {
        $default = ScanJson (Invoke-Scan)
        $narrow  = ScanJson (Invoke-Scan -Extra @('-Window', '1'))
        $default.signals.PSObject.Properties.Name | Should -Contain 'repetition'
        @($narrow.signals.PSObject.Properties.Name) | Should -Not -Contain 'repetition'
    }
}

Describe 'Invoke-FieldScan -MatchFiled - recurrence vs new candidate (#476)' {
    It 'without -MatchFiled nothing is matched and the shape says so' {
        $r = Invoke-Scan
        $r.Exit | Should -Be 0
        $j = ScanJson $r
        $j.matchFiled | Should -BeFalse
        @($j.recurrence).Count | Should -Be 0
    }
    It 'a script whose incidents are already filed is a RECURRENCE, with the filed issues listed' {
        $j = ScanJson (Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands))
        $plan = @($j.recurrence) | Where-Object tool -eq 'Board-Plan.ps1'
        $plan.status | Should -Be 'recurrence'
        (@($plan.filed).number | Sort-Object) | Should -Be @(10, 11)
    }
    It 'counts the incidents and failures of the sweep against that script' {
        $j = ScanJson (Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands))
        $plan = @($j.recurrence) | Where-Object tool -eq 'Board-Plan.ps1'
        $plan.failures | Should -Be 2
        $plan.incidents | Should -BeGreaterOrEqual 2
        $plan.invocations | Should -Be 2
    }
    It 'a script nobody filed anything about is a NEW candidate, not a recurrence' {
        $j = ScanJson (Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands))
        $b = @($j.recurrence) | Where-Object tool -eq 'Backup-Board.ps1'
        $b.status | Should -Be 'new-candidate'
        @($b.filed).Count | Should -Be 0
    }
    It 'a repetition with NO failure is still an incident (the four signals, not just failures)' {
        $j = ScanJson (Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands))
        $f = @($j.recurrence) | Where-Object tool -eq 'Board-Fill.ps1'
        $f | Should -Not -BeNullOrEmpty
        $f.failures | Should -Be 0
        $f.incidents | Should -BeGreaterOrEqual 1
    }
    It 'does not attach an unrelated issue to a script it never names' {
        $j = ScanJson (Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands))
        (@($j.recurrence | ForEach-Object { $_.filed } | ForEach-Object { $_.number })) | Should -Not -Contain 12
    }
    It 'prints both sections in the human report' {
        $fr = Join-Path $script:Tmp ('field-' + [guid]::NewGuid().ToString('N'))
        $out = (& pwsh -NoProfile -File $script:Scan -FieldRoot $fr -ProjectsRoot $script:Proj -MatchFiled -CandidatesFile $script:Cands 2>&1 | Out-String)
        $out | Should -Match 'reincidencia \(ya archivado\)'
        $out | Should -Match ([regex]::Escape($script:Proj))
        $out | Should -Match 'candidatos NUEVOS'
        $out | Should -Match '#10 \[abierto\]'
        $out | Should -Match '#11 \[cerrado COMPLETED\]'
    }
    It 'a candidates file that cannot be read is REPORTED, and the sweep result is still delivered' {
        $r = Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', (Join-Path $script:Tmp 'nope.json'))
        $r.Exit | Should -Be 0
        $j = ScanJson $r
        $j.recurrenceNote | Should -Match 'no se pudo cotejar'
        $j.scanned | Should -BeGreaterThan 0
        @($j.recurrence).Count | Should -Be 0
    }
    It '-MatchFiled does not clobber the sweep parameters (the dot-source trap)' {
        # -Json must still be honoured after the shared functions are loaded, and -Repo/-ClosedDays
        # must keep the values the caller passed.
        $r = Invoke-Scan -Extra @('-MatchFiled', '-CandidatesFile', $script:Cands, '-Repo', 'me/proj', '-ClosedDays', '7')
        { ScanJson $r } | Should -Not -Throw
    }
}

Describe 'Invoke-FieldScan wiring' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:Scan -Raw }
    It 'loads the shared search functions, not the CLI that has a param block' {
        $script:Src | Should -Match "IssueSearch\.ps1"
        $script:Src | Should -Not -Match "Find-DuplicateIssue\.ps1'\)"
    }
    It 'never files anything - it only reads issues' {
        $script:Src | Should -Not -Match 'issue create|issue comment|issue edit'
    }
}
