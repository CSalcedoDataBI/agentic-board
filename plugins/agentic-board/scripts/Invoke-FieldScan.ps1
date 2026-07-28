<#
.SYNOPSIS
    /board field — sweep local session transcripts and report how agentic-board behaved (#476).

.DESCRIPTION
    Joins stage 1 (Get-FieldLedger: which sessions still owe work) to stage 2 (Get-FieldEpisodes:
    what happened around each invocation). Incremental by watermark, so a second run minutes later
    does nothing.

    Read-only over ~/.claude/projects. Everything it writes goes to the field root, which lives
    outside any repo — the local record cannot be committed by construction. Nothing is filed to
    GitHub here: this produces candidates for a human to judge.

.EXAMPLE
    Invoke-FieldScan.ps1                 # sweep whatever is new
    Invoke-FieldScan.ps1 -WhatIf         # show what would be read, touch nothing
    Invoke-FieldScan.ps1 -Limit 20       # bound a first run
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FieldRoot,
    [string]$ProjectsRoot,
    [int]$Window = 6,
    [int]$Limit = 0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$prevL = $env:ABIOS_FIELDLEDGER_DOTSOURCE
$prevE = $env:ABIOS_FIELDEPISODES_DOTSOURCE
$env:ABIOS_FIELDLEDGER_DOTSOURCE   = '1'
$env:ABIOS_FIELDEPISODES_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Get-FieldLedger.ps1')
. (Join-Path $PSScriptRoot 'Get-FieldEpisodes.ps1')
$env:ABIOS_FIELDLEDGER_DOTSOURCE   = $prevL
$env:ABIOS_FIELDEPISODES_DOTSOURCE = $prevE

$root       = Get-FieldRoot -Override $FieldRoot
$transcript = Get-TranscriptRoot -Override $ProjectsRoot
$ledgerPath = Join-Path $root 'ledger.csv'
$recordDir  = Join-Path $root 'episodes'

Write-Host "=== /board field  —  sweep ===" -ForegroundColor Cyan
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
    try {
        $reader = [System.IO.File]::OpenText($src.path)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
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
    if ($episodes.Count) {
        $withTool++
        $totalEpisodes += $episodes.Count
        foreach ($e in $episodes) {
            $toolTally[$e.tool] = 1 + [int]$toolTally[$e.tool]
            foreach ($s in $e.signals) { $signalTally[$s] = 1 + [int]$signalTally[$s] }
        }
        # Per-session record, redacted. Traceable back to the transcript by event index.
        $rec = [pscustomobject]@{
            sessionId = $p.sessionId; project = $p.project; scannedAt = (Get-Date).ToUniversalTime().ToString('o')
            events = $src.events
            episodes = @($episodes | ForEach-Object {
                [pscustomobject]@{ index = $_.index; tool = Protect-FieldText -Text $_.tool; failed = $_.failed; signals = $_.signals }
            })
        }
        $rec | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $recordDir "$($p.project)__$($p.sessionId).json") -Encoding UTF8
    }

    # Only now — the events were actually processed.
    $ledger = @(Update-LedgerRow -Ledger $ledger -SessionId $p.sessionId -Project $p.project `
                    -Events $src.events -Bytes $src.bytes -Incidents $episodes.Count -UsedTool $used `
                    -ScannedAt ((Get-Date).ToUniversalTime().ToString('o')))
}
Write-Progress -Activity "Escaneando sesiones" -Completed

Write-FieldLedger -Path $ledgerPath -Ledger $ledger | Out-Null

$summary = [pscustomobject]@{
    scanned        = $n
    sessionsWithTool = $withTool
    episodes       = $totalEpisodes
    signals        = $signalTally
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
Write-Host "`n  ledger  : $ledgerPath"
Write-Host "  registro: $recordDir"
Write-Host "`nNada se archivó en GitHub: esto son candidatos para que un humano juzgue." -ForegroundColor DarkGray
