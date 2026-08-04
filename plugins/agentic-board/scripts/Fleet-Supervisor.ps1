<#
.SYNOPSIS
    Fleet supervisor: stall detection + fleet termination policy (Phase 3, P3-5).

.DESCRIPTION
    Watches the live /board work fleet (from .agentic-board/sessions.json) and produces a
    verdict:
      - which sessions have STALLED (running past -ThresholdMin with no PR opened yet),
      - whether the whole run is COMPLETE (every session's PR merged),
      - whether it should STOP - the guard against a runaway fleet: complete, or too many
        stalled sessions (-MaxStalled).
    Stalled sessions are surfaced with a suggestion to re-plan (Fleet-Plan.ps1) or take them
    over; it never kills anything itself (that is Phase 2's reaper).

    Pure verdict core (Test-SessionStalled / Get-StalledSessions / Test-FleetComplete /
    Get-FleetVerdict) sits behind a dot-source guard ($env:ABIOS_FLEETSUPERVISOR_DOTSOURCE)
    for unit tests; only the CLI reads sessions.json + gh.

.PARAMETER Check
    Read the live fleet and print the verdict.

.PARAMETER Post
    Post an `[abios-stall]` comment on each STALLED session's issue (once per issue, deduped by
    a marker in the state dir) so the stall is visible where the human already looks (#565).
    Until this, the verdict existed only on a terminal nobody was required to be watching.

.PARAMETER ThresholdMin
    Minutes with no PR before a session counts as stalled. Default 30.

.PARAMETER MaxStalled
    Stalled-session count that trips a STOP. Default 2.

.EXAMPLE
    .\Fleet-Supervisor.ps1 -Check
    .\Fleet-Supervisor.ps1 -Check -ThresholdMin 45 -MaxStalled 3 -Json
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Post,
    [int]$ProjectNum = 0,
    [int]$ThresholdMin = 30,
    [int]$MaxStalled = 2,
    [string]$Owner = "CSalcedoDataBI",
    [switch]$Json,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)
$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# ------------------------------------------------------------------ pure verdict core
# A session is stalled when it has run past the threshold with NO PR yet (an open PR is
# progress, so it is never stalled). Pure -> unit-testable.
function Test-SessionStalled {
    param([object]$Session, [int]$ThresholdMin)
    return ([string]::IsNullOrEmpty("$($Session.pr)")) -and ([int]$Session.ageMin -gt $ThresholdMin)
}

function Get-StalledSessions {
    param([object[]]$Sessions, [int]$ThresholdMin)
    return @($Sessions | Where-Object { $null -ne $_ -and (Test-SessionStalled $_ $ThresholdMin) })
}

# The fleet is complete when every session's PR is merged (an empty fleet is trivially so).
function Test-FleetComplete {
    param([object[]]$Sessions)
    $s = @($Sessions | Where-Object { $null -ne $_ })
    if ($s.Count -eq 0) { return $true }
    return (@($s | Where-Object { -not $_.merged }).Count -eq 0)
}

# The stall comment body. Pure, so tests pin the wording that reaches the human (#565).
function New-StallCommentBody {
    param([int]$Issue = 0, [int]$AgeMin = 0, [int]$ThresholdMin = 30)
    return @"
<!-- [abios-stall] issue=$Issue -->
## Autonomous run signal — session STALLED

The session working #$Issue has been running **$AgeMin minutes with no PR** (threshold:
$ThresholdMin min). It may be stuck, waiting on something, or dead. Check
``.agentic-board/logs/issue-$Issue.log``, or take the issue over with
``Board-Work.ps1 -Start $Issue -TakeOver``.

*(Posted once per issue by the fleet supervisor — #565.)*
"@
}

# The termination verdict: stop when the fleet is complete OR too many sessions have stalled.
function Get-FleetVerdict {
    param([object[]]$Sessions, [int]$ThresholdMin, [int]$MaxStalled)
    $complete = Test-FleetComplete $Sessions
    $stalled  = @(Get-StalledSessions $Sessions $ThresholdMin)
    $shouldStop = $complete -or ($stalled.Count -ge $MaxStalled)
    $reason = if ($complete) { 'fleet complete - every session merged' }
              elseif ($stalled.Count -ge $MaxStalled) { "stalled - $($stalled.Count) session(s) past ${ThresholdMin}min with no PR" }
              else { 'in progress' }
    return [pscustomobject]@{
        complete   = $complete
        stalled    = $stalled
        shouldStop = $shouldStop
        reason     = $reason
    }
}

# ------------------------------------------------------------- I/O (sessions.json + gh)
function Get-SessionsFile {
    $state = Get-AbiosStateDir -NoCreate
    if (-not $state) { return $null }
    return (Join-Path $state "sessions.json")
}

function Read-FleetSessions {
    $p = Get-SessionsFile
    if (-not $p -or -not (Test-Path $p)) { return @() }
    try { return @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return @() }
}

# Enrich raw registry entries with ageMin (from `started`) + pr/merged (from gh).
function Resolve-LiveSessions {
    $out = @()
    foreach ($e in (Read-FleetSessions)) {
        $ageMin = 0
        try { $ageMin = [int]((Get-Date) - [datetime]::ParseExact($e.started, 'yyyy-MM-dd HH:mm', $null)).TotalMinutes } catch { }
        $pr = ''; $merged = $false
        if ($e.repo -and $e.branch) {
            try {
                $found = @(gh pr list --repo $e.repo --head $e.branch --state all --json number,state --limit 1 2>$null | ConvertFrom-Json)
                if ($found.Count -gt 0) { $pr = "#$($found[0].number)"; $merged = ($found[0].state -eq 'MERGED') }
            } catch { }
        }
        $out += [pscustomobject]@{ issue = $e.issue; repo = $e.repo; branch = $e.branch; started = "$($e.started)"; ageMin = $ageMin; pr = $pr; merged = $merged }
    }
    return $out
}

# The dedup key for one stalled SESSION - repo + issue + start time, sanitized for a filename
# (#565 review): keyed on the issue number alone, a relaunch of the same issue (or the same
# number in another repo) was suppressed by the ghost of an earlier session's marker. Pure.
function Get-StallMarkerName {
    param([Parameter(Mandatory)]$Session)
    $san = { param($s) ("$s" -replace '[^A-Za-z0-9]', '-') }
    return ("signal-stall-{0}-{1}-{2}.posted" -f (& $san $Session.repo), [int]$Session.issue, (& $san $Session.started))
}

# Post the [abios-stall] comment for each stalled session, once per SESSION (marker in the state
# dir). Best-effort: a posting failure is a WARN, never a changed verdict.
function Publish-StallSignals {
    param([object[]]$Stalled, [int]$ThresholdMin)
    $state = Get-AbiosStateDir
    foreach ($s in @($Stalled)) {
        if (-not $s.issue -or -not $s.repo) { continue }
        $mark = if ($state) { Join-Path $state (Get-StallMarkerName -Session $s) } else { $null }
        if ($mark -and (Test-Path -LiteralPath $mark)) { continue }
        try {
            $body = New-StallCommentBody -Issue ([int]$s.issue) -AgeMin ([int]$s.ageMin) -ThresholdMin $ThresholdMin
            & gh issue comment "$($s.issue)" --repo "$($s.repo)" --body $body 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if ($mark) { Set-Content -LiteralPath $mark -Encoding UTF8 -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) }
                Write-Host ("  OK  senal [abios-stall] publicada en #{0}" -f $s.issue) -ForegroundColor Green
            } else {
                Write-Host ("  WARN no pude publicar la senal de estancamiento en #{0}" -f $s.issue) -ForegroundColor DarkYellow
            }
        } catch {
            Write-Host ("  WARN no pude publicar la senal de estancamiento en #{0}: {1}" -f $s.issue, $_) -ForegroundColor DarkYellow
        }
    }
}

# --- dot-source guard: stop here so unit tests get the pure core with no I/O -----
if ($env:ABIOS_FLEETSUPERVISOR_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }

$sessions = @(Resolve-LiveSessions)
$verdict  = Get-FleetVerdict $sessions $ThresholdMin $MaxStalled

if ($Json) { $verdict | ConvertTo-Json -Depth 6; return }

Write-Host "=== Supervisor del fleet ===" -ForegroundColor Cyan
if ($sessions.Count -eq 0) {
    Write-Host "  (no hay sesiones vivas registradas)" -ForegroundColor DarkGray
    return
}
foreach ($s in ($sessions | Sort-Object issue)) {
    $tag = if ($s.merged) { 'merged' } elseif ($s.pr) { 'in review' } elseif ($s.ageMin -gt $ThresholdMin) { 'STALLED' } else { 'working' }
    $color = switch ($tag) { 'merged' { 'Green' } 'in review' { 'DarkCyan' } 'STALLED' { 'Red' } default { 'Yellow' } }
    Write-Host ("  #{0,-4} {1,-9} {2,4}min  {3}" -f $s.issue, $tag, $s.ageMin, $s.pr) -ForegroundColor $color
}
Write-Host ""
Write-Host ("Veredicto: {0}" -f $verdict.reason) -ForegroundColor Cyan
if (@($verdict.stalled).Count -gt 0) {
    Write-Host ("  Estancados: {0}" -f ((@($verdict.stalled).issue) -join ', ')) -ForegroundColor Red
    Write-Host "  Sugerencia: re-planifica (Fleet-Plan.ps1) o retoma con Board-Work.ps1 -Start <n> -TakeOver." -ForegroundColor DarkYellow
    if ($Post) { Publish-StallSignals -Stalled @($verdict.stalled) -ThresholdMin $ThresholdMin }
}
if ($verdict.shouldStop) {
    Write-Host "  >> STOP: el fleet deberia detenerse." -ForegroundColor Magenta
} else {
    Write-Host "  >> CONTINUE: hay trabajo en curso." -ForegroundColor DarkGray
}
