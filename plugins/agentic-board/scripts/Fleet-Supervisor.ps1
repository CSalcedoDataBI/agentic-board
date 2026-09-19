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

# The brake marker reader (#517): the supervisor asks whether a session's run was armed.
. (Join-Path $PSScriptRoot 'Brake-Guard.ps1')

# ------------------------------------------------------------------ pure verdict core
# A session is stalled when it has run AT LEAST the threshold with NO PR yet (an open PR is
# progress, so it is never stalled). Inclusive on purpose (#565 round 7): the watch's final
# supervisor pass fires at its timeout, and with `-gt` a session at exactly the threshold slid
# under it - the default 30-min watch ended with the 30-min stall never posted. Pure.
function Test-SessionStalled {
    param([object]$Session, [int]$ThresholdMin)
    return ([string]::IsNullOrEmpty("$($Session.pr)")) -and ([int]$Session.ageMin -ge $ThresholdMin)
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
    param([int]$Issue = 0, [int]$AgeMin = 0, [int]$ThresholdMin = 30, [int]$ProjectNum = 0)
    # The suggested command must be RUNNABLE as pasted (#565 round 12): Board-Work refuses
    # -Start without -ProjectNum, so the board number rides along when known.
    $projArg = if ($ProjectNum -gt 0) { "-ProjectNum $ProjectNum " } else { "-ProjectNum <board> " }
    return @"
<!-- [abios-stall] issue=$Issue -->
## Autonomous run signal — session STALLED

The session working #$Issue has been running **$AgeMin minutes with no PR** (threshold:
$ThresholdMin min). It may be stuck, waiting on something, or dead. Check
``.agentic-board/logs/issue-$Issue.log``, or take the issue over with
``Board-Work.ps1 $projArg-Start $Issue -TakeOver``.

*(Posted once per issue by the fleet supervisor — #565.)*
"@
}

# A brake-armed run whose PR ended up MERGED (#517). The brake is a control, and a control whose
# breach is only ever self-reported by the agent that breached it is not one: this detects it from
# the observable record - the marker the launcher wrote and the PR state on GitHub - instead of
# asking the agent. It cannot tell a human's merge after review (expected) from the run merging
# itself (the violation), so it REPORTS with who merged and when, and lets the human judge; it never
# acts. Only a run whose contract braked on `merge` counts (a budget-only or merge-allowed contract
# is not breached by a merge). Pure. ADDS a report - nothing it does changes any other verdict.
function Get-BrakeViolations {
    param([object[]]$Sessions)
    return @($Sessions | Where-Object {
        $null -ne $_ -and $_.merged -and ($null -ne $_.PSObject.Properties['brakesMerge']) -and $_.brakesMerge
    } | ForEach-Object {
        [pscustomobject]@{
            issue    = $_.issue
            pr       = "$($_.pr)"
            mergedBy = $(if ($null -ne $_.PSObject.Properties['mergedBy']) { "$($_.mergedBy)" } else { '' })
            mergedAt = $(if ($null -ne $_.PSObject.Properties['mergedAt']) { "$($_.mergedAt)" } else { '' })
        }
    })
}

# The wording that reaches the human. Pure, so tests pin it.
function Format-BrakeViolations {
    param([object[]]$Violations)
    $lines = @()
    foreach ($v in @($Violations)) {
        $who = if ($v.mergedBy) { " por $($v.mergedBy)" } else { '' }
        $when = if ($v.mergedAt) { " ($($v.mergedAt))" } else { '' }
        $lines += "  #$($v.issue) $($v.pr) MERGEADO$who$when - la corrida tenia el freno armado (merge = irreversible)"
    }
    if ($lines.Count -gt 0) {
        $lines += "  Si mergeaste tu tras revisar, es lo esperado. Si no, el freno fue saltado: mira .agentic-board/denials.jsonl del worktree (auto-clean lo conserva, #518)."
    }
    return @($lines)
}

# Read the brake facts of one registry entry: is its worktree's run armed, and does it brake on merge?
function Get-SessionBrakeInfo {
    param([string]$WorkPath)
    $marker = $null
    try { $marker = Read-BrakeMarkerAt -WorkPath $WorkPath } catch { $marker = $null }
    return [pscustomobject]@{ brakeArmed = [bool]$marker; brakesMerge = (Test-BrakeMarkerBrakesMerge -Marker $marker) }
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
        complete        = $complete
        stalled         = $stalled
        shouldStop      = $shouldStop
        reason          = $reason
        brakeViolations = @(Get-BrakeViolations $Sessions)
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

# Which PR belongs to THIS session? A branch NAME is not an identity: `-TakeOver` reuses
# `issue-<n>-<slug>`, so `gh pr list --head <branch>` can return an OLD merged PR from a previous run,
# and reporting it as this session's PR would raise a false brake violation (and read the fleet as
# complete) for a relaunch that has no PR yet - the same reason Get-SessionLiveStatus / Select-BranchPr
# refuse "the newest one". Pure. In order of trust:
#   1. the PR whose head IS this session's branch tip ($Tip);
#   2. otherwise the newest PR CREATED at or after the session started (the branch may have moved past
#      the pushed head; a PR opened before this run began cannot be this run's);
#   3. otherwise none - never an older run's PR.
# $Prs items need number, state, headRefOid, createdAt (UTC ISO). $StartedAt is the registry's local
# stamp; both stamp formats (seconds, and the older minutes) parse. An unparseable stamp disables rule 2
# (rule 3 applies): unknown must not adopt somebody else's PR.
function Select-SessionPr {
    param([object[]]$Prs = @(), [string]$Tip = '', [string]$StartedAt = '')
    $all = @($Prs | Where-Object { $null -ne $_ })
    if ($Tip) {
        $byTip = @($all | Where-Object { "$($_.headRefOid)" -eq $Tip }) | Select-Object -First 1
        if ($byTip) { return $byTip }
    }
    $start = $null
    foreach ($fmt in @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm')) {
        try { $start = [datetime]::ParseExact($StartedAt, $fmt, [cultureinfo]::InvariantCulture); break } catch { }
    }
    if (-not $start) { return $null }
    $floor = $start.AddSeconds(-60)
    $later = @($all | Where-Object {
        $c = $null
        try { $c = ([datetimeoffset]::Parse("$($_.createdAt)", [cultureinfo]::InvariantCulture)).LocalDateTime } catch { }
        $c -and $c -ge $floor
    } | Sort-Object { [int]$_.number } -Descending) | Select-Object -First 1
    return $later
}

# The tip of a session's branch, from ITS worktree ('' when it cannot be read).
function Get-SessionBranchTip {
    param([string]$WorkPath, [string]$Branch)
    if (-not $WorkPath -or -not $Branch -or -not (Test-Path -LiteralPath $WorkPath)) { return '' }
    $out = @(git -C $WorkPath rev-parse --verify "$Branch^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -eq 0) { return '' }
    return "$($out[0])".Trim()
}

# Enrich raw registry entries with ageMin (from `started`) + pr/merged (from gh).
function Resolve-LiveSessions {
    $out = @()
    foreach ($e in (Read-FleetSessions)) {
        $ageMin = 0
        # Both stamp formats: rows written before #568 carry minutes, newer ones carry seconds.
        foreach ($fmt in @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm')) {
            try { $ageMin = [int]((Get-Date) - [datetime]::ParseExact($e.started, $fmt, $null)).TotalMinutes; break } catch { }
        }
        # prKnown separates "no PR" from "could not read" (#565 review round 4): a transient gh
        # failure used to read as pr='' - tolerable for a terminal warning, but -Post publishes
        # comments from this fact, and a false [abios-stall] on a session that HAS a PR is noise
        # that costs the signal its credibility.
        $pr = ''; $merged = $false; $prKnown = $false; $mergedBy = ''; $mergedAt = ''
        if ($e.repo -and $e.branch) {
            try {
                $raw = gh pr list --repo $e.repo --head $e.branch --state all --json number,state,headRefOid,createdAt,mergedBy,mergedAt --limit 20 2>$null
                if ($LASTEXITCODE -eq 0 -and $null -ne $raw) {
                    $prKnown = $true
                    $mine = Select-SessionPr -Prs @($raw | ConvertFrom-Json) -Tip (Get-SessionBranchTip -WorkPath "$($e.workPath)" -Branch "$($e.branch)") -StartedAt "$($e.started)"
                    if ($mine) {
                        $pr = "#$($mine.number)"; $merged = ($mine.state -eq 'MERGED')
                        if ($mine.mergedBy) { $mergedBy = "$($mine.mergedBy.login)" }
                        if ($mine.mergedAt) { $mergedAt = "$($mine.mergedAt)" }
                    }
                }
            } catch { $prKnown = $false }
        }
        $brake = Get-SessionBrakeInfo -WorkPath "$($e.workPath)"
        $out += [pscustomobject]@{ issue = $e.issue; repo = $e.repo; branch = $e.branch; started = "$($e.started)"; ageMin = $ageMin; pr = $pr; merged = $merged; prKnown = $prKnown
                                   brakeArmed = $brake.brakeArmed; brakesMerge = $brake.brakesMerge; mergedBy = $mergedBy; mergedAt = $mergedAt }
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
    param([object[]]$Stalled, [int]$ThresholdMin, [int]$BoardNum = 0, [switch]$Quiet)
    $state = Get-AbiosStateDir
    foreach ($s in @($Stalled)) {
        if (-not $s.issue -or -not $s.repo) { continue }
        # Only post a stall whose "no PR" fact was actually ESTABLISHED (round 4): if the PR
        # lookup failed, this session may well have one, and a false stall comment is noise.
        if (($null -ne $s.PSObject.Properties['prKnown']) -and -not $s.prKnown) { continue }
        $mark = if ($state) { Join-Path $state (Get-StallMarkerName -Session $s) } else { $null }
        if ($mark -and (Test-Path -LiteralPath $mark)) { continue }
        try {
            # Marker FIRST, like the hook path (round 13): a post that lands on GitHub while the
            # local process dies would otherwise repost next cycle - the no-flooding guarantee
            # outranks a lost comment, and the loss direction is stated, not pretended.
            if ($mark) { Set-Content -LiteralPath $mark -Encoding UTF8 -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) }
            $body = New-StallCommentBody -Issue ([int]$s.issue) -AgeMin ([int]$s.ageMin) -ThresholdMin $ThresholdMin -ProjectNum $BoardNum
            # Bounded like the hook's signal post (#565 review round 2): this now runs inside the
            # session watch loop, and a hung gh call would wedge the watch - best-effort must
            # stay best-effort. Body by file, 15 seconds, then the child is killed.
            $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("abios-stall-" + [guid]::NewGuid().ToString('N') + ".md")
            Set-Content -LiteralPath $bodyFile -Encoding UTF8 -Value $body
            $exit = 1
            try {
                $proc = Start-Process -FilePath 'gh' -ArgumentList @(
                            'issue','comment',"$($s.issue)",'--repo',"$($s.repo)",'--body-file',$bodyFile
                        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "abios-stall-out-" + [guid]::NewGuid().ToString('N'))) `
                          -RedirectStandardError  ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "abios-stall-err-" + [guid]::NewGuid().ToString('N')))
                if ($proc.WaitForExit(15000)) { $exit = $proc.ExitCode } else { try { $proc.Kill() } catch { } }
            } finally {
                Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
            }
            if ($exit -eq 0) {
                if (-not $Quiet) { Write-Host ("  OK  senal [abios-stall] publicada en #{0}" -f $s.issue) -ForegroundColor Green }
            } elseif (-not $Quiet) {
                Write-Host ("  WARN no pude publicar la senal de estancamiento en #{0}" -f $s.issue) -ForegroundColor DarkYellow
            }
        } catch {
            if (-not $Quiet) { Write-Host ("  WARN no pude publicar la senal de estancamiento en #{0}: {1}" -f $s.issue, $_) -ForegroundColor DarkYellow }
        }
    }
}

# --- dot-source guard: stop here so unit tests get the pure core with no I/O -----
if ($env:ABIOS_FLEETSUPERVISOR_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }

$sessions = @(Resolve-LiveSessions)
$verdict  = Get-FleetVerdict $sessions $ThresholdMin $MaxStalled

if ($Json) {
    # -Post still posts under -Json (round 9): the early return silently made the switch a no-op
    # for exactly the automation (watch loops, scripts) most likely to combine them. -Quiet keeps
    # the stdout contract pure JSON (round 10) - publisher status must not corrupt the payload.
    if ($Post -and @($verdict.stalled).Count -gt 0) { Publish-StallSignals -Stalled @($verdict.stalled) -ThresholdMin $ThresholdMin -BoardNum $ProjectNum -Quiet }
    $verdict | ConvertTo-Json -Depth 6; return
}

Write-Host "=== Supervisor del fleet ===" -ForegroundColor Cyan
if ($sessions.Count -eq 0) {
    Write-Host "  (no hay sesiones vivas registradas)" -ForegroundColor DarkGray
    return
}
foreach ($s in ($sessions | Sort-Object issue)) {
    $tag = if ($s.merged) { 'merged' } elseif ($s.pr) { 'in review' } elseif ($s.ageMin -ge $ThresholdMin) { 'STALLED' } else { 'working' }
    $color = switch ($tag) { 'merged' { 'Green' } 'in review' { 'DarkCyan' } 'STALLED' { 'Red' } default { 'Yellow' } }
    Write-Host ("  #{0,-4} {1,-9} {2,4}min  {3}" -f $s.issue, $tag, $s.ageMin, $s.pr) -ForegroundColor $color
}
Write-Host ""
Write-Host ("Veredicto: {0}" -f $verdict.reason) -ForegroundColor Cyan
if (@($verdict.brakeViolations).Count -gt 0) {
    Write-Host ("  FRENO: {0} sesion(es) con el freno armado tienen su PR MERGEADO:" -f @($verdict.brakeViolations).Count) -ForegroundColor Red
    foreach ($l in (Format-BrakeViolations $verdict.brakeViolations)) { Write-Host $l -ForegroundColor Red }
}
if (@($verdict.stalled).Count -gt 0) {
    Write-Host ("  Estancados: {0}" -f ((@($verdict.stalled).issue) -join ', ')) -ForegroundColor Red
    Write-Host "  Sugerencia: re-planifica el fleet o retoma con /board work -Start <n> -TakeOver." -ForegroundColor DarkYellow
    if ($Post) { Publish-StallSignals -Stalled @($verdict.stalled) -ThresholdMin $ThresholdMin -BoardNum $ProjectNum }
}
if ($verdict.shouldStop) {
    Write-Host "  >> STOP: el fleet deberia detenerse." -ForegroundColor Magenta
} else {
    Write-Host "  >> CONTINUE: hay trabajo en curso." -ForegroundColor DarkGray
}
