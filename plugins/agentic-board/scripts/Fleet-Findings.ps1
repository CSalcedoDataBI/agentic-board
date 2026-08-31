<#
.SYNOPSIS
    Fleet shared-findings blackboard (Phase 3, P3-1) - a shared brain for the /board
    work parallel fleet.

.DESCRIPTION
    The parallel fleet (/board work -Parallel/-Launch) runs each issue in its own git
    worktree. Today those sessions only AVOID collisions (claim + sessions.json); they
    do not SHARE what they learn. This is the blackboard: a shared findings file each
    worktree writes on progress/completion, so the next session reads prior findings
    (files touched, decisions, gotchas) before starting and never re-derives them.

    Like sessions.json, the store lives next to the MAIN clone's .git
    (git rev-parse --git-common-dir) inside .agentic-board/fleet/findings.json, so
    every worktree of the repo sees the same one. It is gitignored (state, not code).

    Entries are UPSERTED by issue: a second write for the same issue unions its arrays
    (filesTouched / decisions / gotchas / labels, de-duplicated) and refreshes the
    scalar fields (status / pr / ts), never duplicating the row.

    Same conventions as the rest of the plugin: pure-ASCII source, pure helpers behind
    a dot-source guard ($env:ABIOS_FLEETFINDINGS_DOTSOURCE) for unit tests, no token
    needed (findings never touch gh).

.PARAMETER Add
    Record (upsert) a finding for -Issue. Combine with -Files/-Decisions/-Gotchas/
    -Labels/-Pr/-Status.

.PARAMETER List
    Read the blackboard. Narrow with -Issue / -Label / -Text; -Json for raw output.

.PARAMETER Issue
    With -Add: the issue the finding belongs to (required). With -List: filter to it.

.PARAMETER Files
    Files touched (comma-joined or a native array; the pwsh -File "a,b" case is split).

.PARAMETER Decisions
    Design/implementation decisions worth sharing (free text; one per token).

.PARAMETER Gotchas
    Pitfalls a sibling session should know before touching the same area.

.PARAMETER Labels
    Tags for retrieval by type (comma-joined or array).

.PARAMETER Pr
    The PR URL/number opened for the issue.

.PARAMETER Status
    in-progress (default) or done.

.PARAMETER Label
    With -List: keep only findings carrying this label (case-insensitive).

.PARAMETER Text
    With -List: keep only findings whose decisions/gotchas/files contain this text.

.PARAMETER Json
    With -List: emit raw JSON instead of the formatted view.

.EXAMPLE
    .\Fleet-Findings.ps1 -Add -Issue 239 -Files "scripts/Fleet-Findings.ps1" -Decisions "state lives next to main .git" -Status done -Pr "https://github.com/o/r/pull/1"
    .\Fleet-Findings.ps1 -List
    .\Fleet-Findings.ps1 -List -Issue 239
    .\Fleet-Findings.ps1 -List -Text pagination -Json
#>
[CmdletBinding()]
param(
    [switch]$Add,
    [switch]$List,
    [int]$Issue = 0,
    [string]$Repo = "",
    [string]$Branch = "",
    [string[]]$Files = @(),
    [string[]]$Decisions = @(),
    [string[]]$Gotchas = @(),
    [string[]]$Labels = @(),
    [string]$Pr = "",
    [ValidateSet('in-progress','done')][string]$Status = 'in-progress',
    [string]$Label = "",
    [string]$Text = "",
    [switch]$Json
)
$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# ------------------------------------------------------------------ pure helpers
# Split comma-joined tokens into a de-duplicated, trimmed array. Mirrors
# Get-ParallelQueue in Board-Work.ps1: `pwsh -File ... -Files "a,b"` arrives as the
# single string "a,b", so every token is split on ',' as well as honoring a native
# multi-element array. Pure -> unit-testable.
function Split-CsvArg {
    param([string[]]$Tokens)
    $out = @()
    foreach ($t in $Tokens) {
        if ($null -eq $t) { continue }
        foreach ($p in ($t -split ',')) {
            $p = $p.Trim()
            if ($p -eq '') { continue }
            if ($out -notcontains $p) { $out += $p }
        }
    }
    return $out
}

# Build one finding record. -Now is injected (not read from the clock) so the shape
# is deterministic for tests; the CLI passes the current timestamp. Files/Labels are
# comma-split; Decisions/Gotchas are free text (kept verbatim, empties dropped). Pure.
function New-FleetFinding {
    param(
        [int]$Issue,
        [string]$Repo = "",
        [string]$Branch = "",
        [string[]]$Files = @(),
        [string[]]$Decisions = @(),
        [string[]]$Gotchas = @(),
        [string[]]$Labels = @(),
        [string]$Pr = "",
        [ValidateSet('in-progress','done')][string]$Status = 'in-progress',
        [string]$HostName = "",
        [string]$Now = ""
    )
    $keep = { param($a) @($a | Where-Object { $null -ne $_ -and "$_".Trim() -ne '' }) }
    [pscustomobject]@{
        issue        = $Issue
        repo         = $Repo
        branch       = $Branch
        filesTouched = @(Split-CsvArg $Files)
        decisions    = @(& $keep $Decisions)
        gotchas      = @(& $keep $Gotchas)
        labels       = @(Split-CsvArg $Labels)
        pr           = $Pr
        status       = $Status
        host         = $HostName
        ts           = $Now
    }
}

# Union two arrays: existing first, then new, de-duplicated, empties dropped. Pure.
function Join-FindingArray {
    param($A, $B)
    $out = @()
    foreach ($x in (@($A) + @($B))) {
        if ($null -ne $x -and "$x".Trim() -ne '' -and $out -notcontains $x) { $out += $x }
    }
    return $out
}

# Upsert $New into $Existing keyed by issue: a matching row unions its array fields
# and refreshes non-empty scalars, keeping its position; otherwise $New is appended.
# Returns a NEW array (does not mutate the input). Pure -> unit-testable.
function Merge-FleetFinding {
    param([object[]]$Existing, [object]$New)
    $list = @($Existing | Where-Object { $null -ne $_ })
    $idx = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ([int]$list[$i].issue -eq [int]$New.issue) { $idx = $i; break }
    }
    if ($idx -lt 0) { return @($list + $New) }
    $cur = $list[$idx]
    $merged = [pscustomobject]@{
        issue        = [int]$cur.issue
        repo         = if ($New.repo)   { $New.repo }   else { $cur.repo }
        branch       = if ($New.branch) { $New.branch } else { $cur.branch }
        filesTouched = @(Join-FindingArray $cur.filesTouched $New.filesTouched)
        decisions    = @(Join-FindingArray $cur.decisions    $New.decisions)
        gotchas      = @(Join-FindingArray $cur.gotchas      $New.gotchas)
        labels       = @(Join-FindingArray $cur.labels       $New.labels)
        pr           = if ($New.pr)     { $New.pr }     else { $cur.pr }
        status       = if ($New.status) { $New.status } else { $cur.status }
        host         = if ($New.host)   { $New.host }   else { $cur.host }
        ts           = if ($New.ts)     { $New.ts }     else { $cur.ts }
    }
    $copy = @($list)
    $copy[$idx] = $merged
    return @($copy)
}

# Filter findings by issue / label (case-insensitive) / free text over the
# decisions+gotchas+files of each entry. Filters AND together; none -> all. Pure.
function Select-FleetFindings {
    param([object[]]$All, [int]$Issue = 0, [string]$Label = "", [string]$Text = "")
    $res = @($All | Where-Object { $null -ne $_ })
    if ($Issue -gt 0) { $res = @($res | Where-Object { [int]$_.issue -eq $Issue }) }
    if ($Label)       { $res = @($res | Where-Object { @($_.labels) -contains $Label }) }
    if ($Text) {
        $t = $Text.ToLower()
        $res = @($res | Where-Object {
            $hay = ((@($_.decisions) + @($_.gotchas) + @($_.filesTouched)) -join "`n").ToLower()
            $hay.Contains($t)
        })
    }
    return $res
}

# ------------------------------------------------------------- disk (side-effecting)
# The blackboard path: <state-dir>/fleet/findings.json next to the MAIN clone's
# .git, shared across every worktree of the repo. Returns $null outside a git repo.
function Get-FleetFindingsPath {
    $state = Get-AbiosStateDir
    if (-not $state) { return $null }
    $dir = Join-Path $state "fleet"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    return (Join-Path $dir "findings.json")
}

# Read all findings (empty array if missing/corrupt - a blackboard must never throw).
# JSON deserializes single-element arrays as scalars, so array fields are re-wrapped.
# -Path is injectable for tests; defaults to the resolved store.
function Read-FleetFindings {
    param([string]$Path)
    if (-not $Path) { $Path = Get-FleetFindingsPath }
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try { $data = @(Get-Content $Path -Raw | ConvertFrom-Json) } catch { return @() }
    return @($data | Where-Object { $null -ne $_ } | ForEach-Object {
        $_.filesTouched = @($_.filesTouched | Where-Object { $null -ne $_ })
        $_.decisions    = @($_.decisions    | Where-Object { $null -ne $_ })
        $_.gotchas      = @($_.gotchas      | Where-Object { $null -ne $_ })
        $_.labels       = @($_.labels       | Where-Object { $null -ne $_ })
        $_
    })
}

# Upsert one finding into the store (read -> Merge -> write), always as a JSON array.
function Write-FleetFinding {
    param([string]$Path, [object]$Finding)
    if (-not $Path) { $Path = Get-FleetFindingsPath }
    if (-not $Path) { return }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $merged = @(Merge-FleetFinding (Read-FleetFindings -Path $Path) $Finding)
    $merged | ConvertTo-Json -Depth 6 -AsArray | Set-Content -Path $Path -Encoding UTF8
}

# Human-readable render of a set of findings.
function Show-FleetFindings {
    param([object[]]$Findings)
    if (-not $Findings -or @($Findings).Count -eq 0) {
        Write-Host "  (pizarra vacia)" -ForegroundColor DarkGray
        return
    }
    foreach ($f in @($Findings | Sort-Object { [int]$_.issue })) {
        Write-Host ("  #{0} [{1}] {2}" -f $f.issue, $f.status, $f.branch) -ForegroundColor Yellow
        if (@($f.filesTouched).Count -gt 0) {
            Write-Host ("      files: {0}" -f (@($f.filesTouched) -join ', ')) -ForegroundColor DarkGray
        }
        foreach ($d in @($f.decisions)) { Write-Host ("      + {0}" -f $d) -ForegroundColor Gray }
        foreach ($g in @($f.gotchas))   { Write-Host ("      ! {0}" -f $g) -ForegroundColor DarkYellow }
        if ($f.pr) { Write-Host ("      PR: {0}" -f $f.pr) -ForegroundColor DarkCyan }
    }
}

# --- dot-source guard: stop here so unit tests get the pure helpers with no I/O -----
if ($env:ABIOS_FLEETFINDINGS_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
if ($Add) {
    if ($Issue -le 0) { throw "-Add requiere -Issue <n>." }
    $now     = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $machine = "$env:COMPUTERNAME"
    $finding = New-FleetFinding -Issue $Issue -Repo $Repo -Branch $Branch -Files $Files `
                   -Decisions $Decisions -Gotchas $Gotchas -Labels $Labels -Pr $Pr `
                   -Status $Status -HostName $machine -Now $now
    Write-FleetFinding -Finding $finding
    Write-Host ("  OK  Finding registrado en la pizarra para #{0} ({1})" -f $Issue, $Status) -ForegroundColor Green
    $p = Get-FleetFindingsPath
    if ($p) { Write-Host ("      {0}" -f $p) -ForegroundColor DarkGray }
    return
}

if ($List) {
    $all = Read-FleetFindings
    $sel = @(Select-FleetFindings $all -Issue $Issue -Label $Label -Text $Text)
    if ($Json) { $sel | ConvertTo-Json -Depth 6 -AsArray; return }
    Write-Host "=== Pizarra de findings del fleet ===" -ForegroundColor Cyan
    Show-FleetFindings $sel
    Write-Host ("Total: {0} finding(s)." -f $sel.Count) -ForegroundColor Cyan
    return
}

Write-Host "Uso:" -ForegroundColor DarkGray
Write-Host "  registro de findings: -Add -Issue <n> [-Files ..] [-Decisions ..] [-Gotchas ..] [-Labels ..] [-Pr ..] [-Status done]" -ForegroundColor DarkGray
Write-Host "  registro de findings: -List [-Issue <n>] [-Label <x>] [-Text <y>] [-Json]" -ForegroundColor DarkGray
