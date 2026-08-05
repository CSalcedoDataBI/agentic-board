<#
.SYNOPSIS
    Garbage-collect .agentic-board/ — the state dir nothing ever cleaned (#574).

.DESCRIPTION
    The architecture review (epic #561) found 48 files accumulated across the project's entire
    life: briefings and launch scripts for issues #123→#532, signal markers, compaction
    snapshots — NOTHING garbage-collected any of it. This is the reaper.

    What it reaps (per-run artifacts, safe to regenerate):
      - briefing-<n>.txt / launch-<n>.ps1 / expert-brief-<n>.md — launch-time artifacts of a
        session that has ended
      - logs/issue-<n>.log — the session's transcript tail
      - signal-*.posted — the run-signal dedup markers (#565)
      - compact-snapshots/*.jsonl — PreCompact transcript copies

    The RULES, and both matter:
      1. A per-issue artifact is reaped only when its issue has NO LIVE SESSION (sessions.json)
         AND the file is older than -MaxAgeDays (default 14). A live session's files are never
         touched, whatever their age.
      2. The DURABLE records are never reaped: sessions.json, sessions-history.jsonl (#568 —
         the only wall-clock archive), active-run.json, expert.json, roles.json, denials.jsonl,
         fleet/*.json, brake-armed.json. This reaper removes REGENERABLE debris, not memory.

    Read-only by default (prints the plan); -Force executes. Pure planning core behind
    $env:ABIOS_CLEARSTATE_DOTSOURCE.

.EXAMPLE
    .\Clear-AbiosState.ps1              # plan only
    .\Clear-AbiosState.ps1 -Force       # reap
    .\Clear-AbiosState.ps1 -MaxAgeDays 30 -Force
#>
[CmdletBinding()]
param(
    [int]$MaxAgeDays = 14,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Pure core ───────────────────────────────────────────────────────────────────

# The shapes this reaper is allowed to touch. ANYTHING not matching stays — an unknown file in
# the state dir is somebody's state, and "unrecognized" must never mean "deletable".
$script:ReapablePatterns = @(
    '^briefing-(\d+)\.txt$'
    '^launch-(\d+)\.ps1$'
    '^expert-brief-(\d+)\.md$'
    '^signal-[a-z]+-.*\.posted$'
)

<#
    Decide what to reap. $Files: objects with RelativePath, Name, AgeDays, IssueNum (0 = not
    per-issue). $LiveIssues: issue numbers with a live session. Returns @{ Reap; Keep } where
    each entry carries the reason — a deletion plan without reasons is not reviewable. Pure.
#>
function Get-StateReapPlan {
    param(
        [object[]]$Files = @(),
        [int[]]$LiveIssues = @(),
        [int]$MaxAgeDays = 14
    )
    $reap = @(); $keep = @()
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $isSnapshot = $f.RelativePath -match '^compact-snapshots[\\/]'
        $isLog      = $f.RelativePath -match '^logs[\\/]issue-(\d+)\.log$'
        $isReapableName = $false
        foreach ($p in $script:ReapablePatterns) { if ($f.Name -match $p) { $isReapableName = $true; break } }
        if (-not ($isSnapshot -or $isLog -or $isReapableName)) {
            $keep += [pscustomobject]@{ File = $f.RelativePath; Reason = 'durable or unrecognized - never reaped' }
            continue
        }
        if ($f.IssueNum -gt 0 -and $LiveIssues -contains [int]$f.IssueNum) {
            $keep += [pscustomobject]@{ File = $f.RelativePath; Reason = "issue #$($f.IssueNum) has a LIVE session" }
            continue
        }
        if ($f.AgeDays -lt $MaxAgeDays) {
            $keep += [pscustomobject]@{ File = $f.RelativePath; Reason = "younger than $MaxAgeDays days" }
            continue
        }
        $reap += [pscustomobject]@{ File = $f.RelativePath; Reason = "regenerable, $([int]$f.AgeDays)d old, no live session" }
    }
    return @{ Reap = @($reap); Keep = @($keep) }
}

# Extract the issue number a per-issue artifact belongs to (0 when none). Pure.
function Get-StateFileIssue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [string]$RelativePath = '')
    if ($RelativePath -match '^logs[\\/]issue-(\d+)\.log$') { return [int]$Matches[1] }
    foreach ($p in $script:ReapablePatterns) {
        if ($Name -match $p) {
            # Capture BEFORE any further -match: a second -match in the same expression
            # overwrites $Matches and this returned 0 for every per-issue shape.
            $num = if ($Matches.Count -gt 1) { "$($Matches[1])" } else { '' }
            if ($num -match '^\d+$') { return [int]$num }
        }
    }
    return 0
}

# Dot-source guard: tests load the pure core only.
if ($env:ABIOS_CLEARSTATE_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
$state = Get-AbiosStateDir -NoCreate
if (-not $state -or -not (Test-Path -LiteralPath $state)) {
    Write-Host "No hay directorio de estado .agentic-board - nada que limpiar." -ForegroundColor DarkGray
    return
}

# Live sessions protect their files (raw read: a dead-PID row still names files worth keeping
# until the teardown archives it).
$liveIssues = @()
$sessionsPath = Join-Path $state 'sessions.json'
if (Test-Path -LiteralPath $sessionsPath) {
    try { $liveIssues = @((Get-Content $sessionsPath -Raw | ConvertFrom-Json) | ForEach-Object { [int]$_.issue }) } catch { $liveIssues = @() }
}

$now = Get-Date
$files = @(Get-ChildItem -LiteralPath $state -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($state.Length).TrimStart('\', '/')
    [pscustomobject]@{
        RelativePath = $rel
        Name         = $_.Name
        FullName     = $_.FullName
        AgeDays      = [Math]::Floor(($now - $_.LastWriteTime).TotalDays)
        IssueNum     = Get-StateFileIssue -Name $_.Name -RelativePath $rel
    }
})

$plan = Get-StateReapPlan -Files $files -LiveIssues $liveIssues -MaxAgeDays $MaxAgeDays

Write-Host "=== Clear-AbiosState  ($state) ===" -ForegroundColor Cyan
Write-Host ("  Archivos: {0}   a limpiar: {1}   se conservan: {2}   (umbral {3} dias)" -f `
    $files.Count, @($plan.Reap).Count, @($plan.Keep).Count, $MaxAgeDays)
foreach ($r in @($plan.Reap)) { Write-Host ("  REAP  {0}  ({1})" -f $r.File, $r.Reason) -ForegroundColor Yellow }
if (@($plan.Reap).Count -eq 0) { Write-Host "  Nada que limpiar." -ForegroundColor Green; return }

if (-not $Force) {
    Write-Host ""
    Write-Host "  Plan solamente - re-ejecuta con -Force para borrar lo listado." -ForegroundColor DarkYellow
    return
}
$byPath = @{}
foreach ($f in $files) { $byPath[$f.RelativePath] = $f.FullName }
$removed = 0
foreach ($r in @($plan.Reap)) {
    try { Remove-Item -LiteralPath $byPath[$r.File] -Force; $removed++ } catch {
        Write-Host ("  WARN no pude borrar {0}: {1}" -f $r.File, $_) -ForegroundColor DarkYellow
    }
}
Write-Host ("  OK  {0} archivo(s) limpiados." -f $removed) -ForegroundColor Green
