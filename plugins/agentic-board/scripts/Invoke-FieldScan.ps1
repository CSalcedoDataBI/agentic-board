<#
.SYNOPSIS
    /board telemetry — sweep local session transcripts and report how agentic-board behaved (#476).

.DESCRIPTION
    Joins stage 1 (Get-FieldLedger: which sessions still owe work) to stage 2 (Get-FieldEpisodes:
    what happened around each invocation). Incremental by watermark, so a second run minutes later
    does nothing.

    Read-only over ~/.claude/projects. Everything it writes goes to the field root, which lives
    outside any repo — the local record cannot be committed by construction. Nothing is filed to
    GitHub here: this produces candidates for a human to judge.

.PARAMETER MatchFiled
    Recurrence matching (#476): after the sweep, join each script that had incidents (a failed
    invocation or any signal) to the issues already filed about it - open ones and those closed in
    the last -ClosedDays - by its NAME. The output then separates RECURRENCE (already filed; here is
    how many more incidents the sweep saw) from NEW CANDIDATES (no filed issue names the script).
    Reads GitHub (read-only); nothing is filed. A failed read is reported and the sweep result is
    still printed - it never turns into "nothing is filed".

.PARAMETER Repo
    owner/name whose issues are matched. Default CSalcedoDataBI/agentic-board.

.PARAMETER ClosedDays
    With -MatchFiled: also match issues closed within this many days. Default 90.

.PARAMETER CandidatesFile
    With -MatchFiled: match against this JSON file (an array of { number, title, body, url, state,
    stateReason }) instead of asking GitHub - offline use, and what the tests feed it.

.EXAMPLE
    Invoke-FieldScan.ps1                 # sweep whatever is new
    Invoke-FieldScan.ps1 -WhatIf         # show what would be read, touch nothing
    Invoke-FieldScan.ps1 -Limit 20       # bound a first run
    Invoke-FieldScan.ps1 -MatchFiled     # also say which incidents are already filed
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FieldRoot,
    [string]$ProjectsRoot,
    [int]$Window = 6,
    [int]$Limit = 0,
    [switch]$Json,
    [switch]$MatchFiled,
    [string]$Repo = 'CSalcedoDataBI/agentic-board',
    [int]$ClosedDays = 90,
    [string]$CandidatesFile = ''
)

$ErrorActionPreference = 'Stop'

# Dot-sourcing runs each file's own param() block IN THIS SCOPE and resets any parameter that shares a
# name with it: Get-FieldLedger declares -FieldRoot/-ProjectsRoot/-Json and Get-FieldEpisodes declares
# -Window/-Json, so -FieldRoot and -ProjectsRoot passed to THIS script were silently dropped and the
# sweep read (and wrote the ledger of) the user's real store no matter what was asked. Caught while
# testing -MatchFiled against a synthetic store; replayed after the loads, like Board-Merge (#536).
$callerParams = @{ FieldRoot = $FieldRoot; ProjectsRoot = $ProjectsRoot; Window = $Window; Json = $Json }
$prevL = $env:ABIOS_FIELDLEDGER_DOTSOURCE
$prevE = $env:ABIOS_FIELDEPISODES_DOTSOURCE
$env:ABIOS_FIELDLEDGER_DOTSOURCE   = '1'
$env:ABIOS_FIELDEPISODES_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Get-FieldLedger.ps1')
. (Join-Path $PSScriptRoot 'Get-FieldEpisodes.ps1')
$env:ABIOS_FIELDLEDGER_DOTSOURCE   = $prevL
$env:ABIOS_FIELDEPISODES_DOTSOURCE = $prevE
$FieldRoot = $callerParams.FieldRoot; $ProjectsRoot = $callerParams.ProjectsRoot
$Window    = $callerParams.Window;    $Json         = $callerParams.Json

$root       = Get-FieldRoot -Override $FieldRoot
$transcript = Get-TranscriptRoot -Override $ProjectsRoot
$ledgerPath = Join-Path $root 'ledger.csv'
$recordDir  = Join-Path $root 'episodes'

Write-Host "=== /board telemetry  —  sweep ===" -ForegroundColor Cyan
Write-Host "  transcripts : $transcript  (read-only)"
Write-Host "  field root  : $root"

$disk    = Get-DiskSessions -Root $transcript
$ledger  = @(Read-FieldLedger -Path $ledgerPath)
$pending = @(Select-SessionsToScan -Disk $disk -Ledger $ledger)

# Biggest first: the long sessions are where the tool was actually exercised.
$pending = @($pending | Sort-Object -Property events -Descending)
if ($Limit -gt 0 -and $pending.Count -gt $Limit) { $pending = @($pending[0..($Limit-1)]) }

Write-Host "  sesiones en disco : $($disk.Count)"
Write-Host "  ya escaneadas     : $($ledger.Count)"
Write-Host "  pendientes        : $($pending.Count)" -ForegroundColor Yellow

if (-not $pending.Count) {
    Write-Host "`nNada nuevo que leer." -ForegroundColor Green
    return
}
if ($WhatIfPreference) {
    Write-Host "`n-WhatIf: no se leyó ni escribió nada." -ForegroundColor DarkGray
    return
}

if (-not (Test-Path -LiteralPath $recordDir)) { New-Item -ItemType Directory -Path $recordDir -Force | Out-Null }

$byPath = @{}
foreach ($d in $disk) { $byPath["$($d.project)/$($d.sessionId)"] = $d }

$totalEpisodes = 0
$signalTally   = @{}
$toolTally     = @{}
$incidentTally = @{}   # episodes that failed OR raised any signal - what recurrence matching joins on
$failTally     = @{}
$withTool      = 0
$n = 0

foreach ($p in $pending) {
    $n++
    $key = "$($p.project)/$($p.sessionId)"
    $src = $byPath[$key]
    if (-not $src) { continue }

    Write-Progress -Activity "Escaneando sesiones" -Status "$n / $($pending.Count)  $($p.project)" -PercentComplete ([int](100 * $n / $pending.Count))

    $events = [System.Collections.Generic.List[object]]::new()
    $i = 0
    # Timestamp bounds of the WHOLE transcript (#568, review round 2): the loop reads every line
    # anyway, so a cheap regex captures the true first/last stamps - the parsed-event subset is
    # pre-filtered (tool_use/tool_result/user) and its bounds undercount the session.
    $fileFirstTs = ''; $fileLastTs = ''
    try {
        $reader = [System.IO.File]::OpenText($src.path)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -match '"timestamp"\s*:\s*"([^"]+)"') {
                    if (-not $fileFirstTs) { $fileFirstTs = $Matches[1] }
                    $fileLastTs = $Matches[1]
                }
                # Cheap pre-filter: a line with none of these markers cannot become an event the
                # detectors use, and ConvertFrom-Json over 571 MB is the whole cost of the sweep.
                if ($i -ge $p.fromEvent -and $line.Length -gt 20 -and
                    ($line.Contains('"tool_use"') -or $line.Contains('"tool_result"') -or $line.Contains('"type":"user"'))) {
                    $e = ConvertTo-FieldEvent -Line $line -Index $i
                    if ($e) { $events.Add($e) }
                }
                $i++
            }
        } finally { $reader.Dispose() }
    } catch {
        Write-Warning "no se pudo leer $key : $($_.Exception.Message)"
        continue   # watermark NOT advanced: a session we failed to read must stay pending
    }

    $episodes = @(Get-FieldEpisodes -Events (Join-FieldResults -Events $events.ToArray()) -Window $Window)
    $used = if ($episodes.Count) { 'yes' } else { 'no' }

    # Session wall-clock (#568) from the FULL transcript bounds captured above - never from the
    # filtered event subset, and immune to incremental watermarks because every scan streams the
    # whole file. UNKNOWN stays $null in memory and in the record file - only the CSV coerces to
    # 0 (a cell cannot hold null); fabricating a zero elsewhere is a claim, not a measurement.
    $firstTs = $fileFirstTs
    $sessionDurationMin = $null
    if ($fileFirstTs -and $fileLastTs) {
        $t0 = ConvertTo-FieldTimestamp -Ts $fileFirstTs
        $t1 = ConvertTo-FieldTimestamp -Ts $fileLastTs
        if ($t0 -and $t1 -and $t1 -ge $t0) { $sessionDurationMin = [int][Math]::Round(($t1 - $t0).TotalMinutes) }
    }

    if ($episodes.Count) {
        $withTool++
        $totalEpisodes += $episodes.Count
        foreach ($e in $episodes) {
            $toolTally[$e.tool] = 1 + [int]$toolTally[$e.tool]
            if ($e.failed) { $failTally[$e.tool] = 1 + [int]$failTally[$e.tool] }
            if ($e.failed -or @($e.signals).Count -gt 0) { $incidentTally[$e.tool] = 1 + [int]$incidentTally[$e.tool] }
            foreach ($s in $e.signals) { $signalTally[$s] = 1 + [int]$signalTally[$s] }
        }
        # Per-session record, redacted. Traceable back to the transcript by event index; carries
        # the time dimension (#568) so later analysis can finally say where the minutes went.
        $rec = [pscustomobject]@{
            sessionId = $p.sessionId; project = $p.project; scannedAt = (Get-Date).ToUniversalTime().ToString('o')
            events = $src.events
            durationMin = $sessionDurationMin
            episodes = @($episodes | ForEach-Object {
                [pscustomobject]@{ index = $_.index; tool = Protect-FieldText -Text $_.tool; failed = $_.failed; signals = $_.signals
                                   ts = $_.ts; durationMs = $_.durationMs }
            })
        }
        $rec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $recordDir "$($p.project)__$($p.sessionId).json") -Encoding UTF8
    }

    # Only now — the events were actually processed. The CSV coerces an unknown duration to 0
    # (a cell cannot hold null); the record file above kept the honest null.
    $ledger = @(Update-LedgerRow -Ledger $ledger -SessionId $p.sessionId -Project $p.project `
                    -Events $src.events -Bytes $src.bytes -Incidents $episodes.Count -UsedTool $used `
                    -DurationMin $(if ($null -eq $sessionDurationMin) { 0 } else { $sessionDurationMin }) -FirstTs $firstTs `
                    -ScannedAt ((Get-Date).ToUniversalTime().ToString('o')))
}
Write-Progress -Activity "Escaneando sesiones" -Completed

Write-FieldLedger -Path $ledgerPath -Ledger $ledger | Out-Null

# Recurrence matching (#476): which of these incidents is a defect somebody already filed? Shares the
# issue-search logic with the pre-filing duplicate check (IssueSearch.ps1 - no param block, so this
# dot-source cannot clobber -Repo / -Json / -ClosedDays above).
$recurrence     = @()
$recurrenceNote = ''
if ($MatchFiled) {
    . (Join-Path $PSScriptRoot 'IssueSearch.ps1')
    try {
        if ($CandidatesFile) {
            if (-not (Test-Path -LiteralPath $CandidatesFile)) { throw "no existe -CandidatesFile '$CandidatesFile'" }
            $cands = @(Get-Content -LiteralPath $CandidatesFile -Raw | ConvertFrom-Json)
        } else {
            # Same identity rule as everything else that talks to GitHub: the owner's account, or the
            # agent's inside a braked run - never a fallback to a broader token.
            $prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
            $env:ABIOS_TOKENVAR_DOTSOURCE = '1'
            . (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
            $env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
            $ctx = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner (($Repo -split '/')[0])
            $env:GH_TOKEN = $ctx.token
            $cands = @(Get-IssueCandidates -Repo $Repo -ClosedDays $ClosedDays)
        }
        $stats = @($toolTally.Keys | ForEach-Object {
            [pscustomobject]@{ tool = $_; invocations = [int]$toolTally[$_]; incidents = [int]$incidentTally[$_]; failures = [int]$failTally[$_] } })
        $recurrence = @(Get-ToolRecurrence -Stats $stats -Candidates $cands)
    } catch {
        $recurrenceNote = "no se pudo cotejar con los issues archivados: $($_.Exception.Message)"
        Write-Warning $recurrenceNote
    }
}

$summary = [pscustomobject]@{
    scanned        = $n
    sessionsWithTool = $withTool
    episodes       = $totalEpisodes
    signals        = $signalTally
    matchFiled     = [bool]$MatchFiled
    recurrence     = $recurrence
    recurrenceNote = $recurrenceNote
    topTools       = ($toolTally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
                      ForEach-Object { "$($_.Key) x$($_.Value)" })
    ledger         = $ledgerPath
    records        = $recordDir
}

if ($Json) { $summary | ConvertTo-Json -Depth 5; return }

Write-Host "`n=== resultado ===" -ForegroundColor Cyan
Write-Host "  sesiones escaneadas    : $n"
Write-Host "  usaron la herramienta  : $withTool"
Write-Host "  episodios              : $totalEpisodes"
if ($signalTally.Count) {
    Write-Host "`n  señales:" -ForegroundColor Yellow
    foreach ($k in ($signalTally.GetEnumerator() | Sort-Object Value -Descending)) {
        Write-Host ("    {0,-12} {1}" -f $k.Key, $k.Value)
    }
}
if ($toolTally.Count) {
    Write-Host "`n  más invocadas:" -ForegroundColor Yellow
    foreach ($k in ($toolTally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8)) {
        Write-Host ("    {0,-28} {1}" -f $k.Key, $k.Value)
    }
}
if ($MatchFiled -and -not $recurrenceNote) {
    $rec = @($recurrence | Where-Object status -eq 'recurrence')
    $new = @($recurrence | Where-Object status -eq 'new-candidate')
    Write-Host "`n  reincidencia (ya archivado):" -ForegroundColor Yellow
    if (-not $rec.Count) { Write-Host '    ninguna' -ForegroundColor DarkGray }
    foreach ($r in $rec) {
        Write-Host ("    {0,-28} {1} incidente(s), {2} fallo(s)" -f $r.tool, $r.incidents, $r.failures)
        foreach ($f in $r.filed) {
            $st = if ($f.state -eq 'OPEN') { 'abierto' } else { "cerrado $($f.stateReason)".Trim() }
            Write-Host ("      #{0} [{1}] {2}" -f $f.number, $st, $f.title) -ForegroundColor DarkGray
        }
    }
    Write-Host "`n  candidatos NUEVOS (ningun issue archivado nombra el script):" -ForegroundColor Yellow
    if (-not $new.Count) { Write-Host '    ninguno' -ForegroundColor DarkGray }
    foreach ($r in $new) { Write-Host ("    {0,-28} {1} incidente(s), {2} fallo(s)" -f $r.tool, $r.incidents, $r.failures) }
}
Write-Host "`n  ledger  : $ledgerPath"
Write-Host "  registro: $recordDir"
Write-Host "`nNada se archivó en GitHub: esto son candidatos para que un humano juzgue." -ForegroundColor DarkGray
