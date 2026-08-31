<#
.SYNOPSIS
    Dependency-aware hand-off (Phase 3, P3-4) for the /board work fleet.

.DESCRIPTION
    A dependent issue (blocked-by another) should not start until its blockers land, and
    when it does start it should inherit what the upstream work learned. This provides both
    halves:
      -Ready   : is the issue's whole blocked-by set closed/merged yet? (exit 0 ready, 1 wait)
      -Context : the hand-off context - a summary of the blockers' blackboard findings
                 (decisions / gotchas / files), to inject into the dependent worker's briefing
                 so it builds on the upstream work instead of re-deriving it.

    Pure core (Get-PendingBlockers / Get-HandoffContext) sits behind a dot-source guard
    ($env:ABIOS_FLEETHANDOFF_DOTSOURCE); only the CLI reads gh + the #239 blackboard.

.PARAMETER Ready
    Check readiness: exit 0 if every blocker is closed, else 1 (and list the open ones).

.PARAMETER Context
    Print the upstream hand-off context (blockers' findings) for -Issue.

.PARAMETER Issue
    The dependent issue.

.PARAMETER Repo
    owner/name (defaults to the origin remote).

.EXAMPLE
    .\Fleet-Handoff.ps1 -Ready   -Issue 242 -Repo CSalcedoDataBI/agentic-board
    .\Fleet-Handoff.ps1 -Context -Issue 242
#>
[CmdletBinding()]
param(
    [switch]$Ready,
    [switch]$Context,
    [int]$Issue = 0,
    [int]$ProjectNum = 0,
    [string]$Owner = "CSalcedoDataBI",
    [string]$Repo = "",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)
$ErrorActionPreference = "Stop"

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# ------------------------------------------------------------------ pure helpers
# The blockers still open: any blocked-by whose entry in $Merged is not $true (an
# unknown blocker is treated as pending - we can't prove it landed). Pure -> testable.
function Get-PendingBlockers {
    param([int[]]$BlockedBy, [hashtable]$Merged)
    return @($BlockedBy | Where-Object { -not $Merged[[int]$_] })
}

# The hand-off context: for each blocker that left a blackboard finding, a short summary
# of its decisions / gotchas / files. Empty string when there is nothing to inherit. Pure.
function Get-HandoffContext {
    param([int[]]$BlockedBy, [object[]]$Findings)
    $parts = @()
    foreach ($b in @($BlockedBy)) {
        $f = @($Findings | Where-Object { [int]$_.issue -eq [int]$b }) | Select-Object -First 1
        if (-not $f) { continue }
        $lines = @("Upstream #$($b):")
        foreach ($d in @($f.decisions)) { if ("$d".Trim() -ne '') { $lines += "  decision: $d" } }
        foreach ($g in @($f.gotchas))   { if ("$g".Trim() -ne '') { $lines += "  gotcha: $g" } }
        if (@($f.filesTouched).Count -gt 0) { $lines += "  files: " + (@($f.filesTouched) -join ', ') }
        $parts += ($lines -join "`n")
    }
    return ($parts -join "`n")
}

# ------------------------------------------------------------- I/O (gh + blackboard)
function Get-FleetFindingsFile {
    $state = Get-AbiosStateDir -NoCreate
    if (-not $state) { return $null }
    return (Join-Path (Join-Path $state "fleet") "findings.json")
}

function Read-BlackboardFindings {
    $p = Get-FleetFindingsFile
    if (-not $p -or -not (Test-Path $p)) { return @() }
    try { return @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return @() }
}

function Get-IssueBlockedBy {
    param([string]$Repo, [int]$Issue)
    try {
        $deps = gh api "repos/$Repo/issues/$Issue/dependencies/blocked_by" 2>$null | ConvertFrom-Json
        return @($deps | ForEach-Object { [int]$_.number })
    } catch { return @() }
}

# --- dot-source guard: stop here so unit tests get the pure helpers with no I/O -----
if ($env:ABIOS_FLEETHANDOFF_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
if ($Issue -le 0) { throw "Especifica -Issue <n>." }
if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "No pude resolver el repo (usa -Repo owner/name)." }

$blockedBy = @(Get-IssueBlockedBy $Repo $Issue)

if ($Context) {
    $ctx = Get-HandoffContext $blockedBy (Read-BlackboardFindings)
    if ($ctx) { Write-Output $ctx }
    else { Write-Host "  (sin contexto upstream - los bloqueadores no dejaron findings en la pizarra)" -ForegroundColor DarkGray }
    return
}

# -Ready (default): a blocker is satisfied when its issue is CLOSED.
$merged = @{}
foreach ($b in $blockedBy) {
    $state = gh issue view $b --repo $Repo --json state --jq .state 2>$null
    $merged[$b] = ($state -eq 'CLOSED')
}
$pending = @(Get-PendingBlockers $blockedBy $merged)
if ($pending.Count -eq 0) {
    Write-Host ("  OK  #{0} listo para arrancar - sus bloqueadores estan cerrados." -f $Issue) -ForegroundColor Green
    exit 0
}
Write-Host ("  WAIT #{0} espera a que cierren: {1}" -f $Issue, ($pending -join ', ')) -ForegroundColor Yellow
exit 1
