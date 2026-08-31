<#
.SYNOPSIS
    Maintain a durable "run-ledger" for a long /board work run so it SURVIVES
    auto-compaction (epic #348).

.DESCRIPTION
    A single-session /board work run that works a queue of issues X->Z fills the
    context window and eventually auto-compacts. The generic summary drops the thread
    (which issues are done, which pending, the key decisions). This script keeps a
    durable ledger of that run in TWO places, mirroring the /board handoff model:

      * DURABLE source of truth: an upserted `<!-- abios-run-ledger -->` comment on the
        EPIC issue (cross-machine, visible, reuses the fail-closed upsert from #316).
      * LOCAL breadcrumb: `.agentic-board/active-run.json` ({epic, board, repo, status,
        ...}). A lockfile-sized marker the OFFLINE SessionStart(compact) hook reads to
        know a run is active and which epic to point back at. The hook never hits the
        network; the reawakened agent re-reads the epic comment in-session.

    Three actions:
      -Start  -Epic <n> [-Board <b>] [-Queue <n,...>]   begin a run
      -Update -Epic <n> -Issue <i> [-Note <s>] [-Next <s>]   record progress on an issue
      -Close  -Epic <n>                                 end the run (marker -> closed)

    Dot-source guard: set $env:ABIOS_RUNLEDGER_DOTSOURCE=1 before dot-sourcing to load
    the pure helpers for Pester WITHOUT the token check or any gh/git side effect.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default GITHUB_TOKEN_PERSONAL.

.PARAMETER DryRun
    Print the marker + intended comment without writing or posting.

.EXAMPLE
    .\Board-RunLedger.ps1 -Start  -Epic 348 -Board 13 -Queue 349,350,351
    .\Board-RunLedger.ps1 -Update -Epic 348 -Issue 349 -Note "reused Invoke-Gh upsert" -Next "wire the hook"
    .\Board-RunLedger.ps1 -Close  -Epic 348
#>
[CmdletBinding()]
param(
    [switch]  $Start,
    [switch]  $Update,
    [switch]  $Close,
    [int]     $Epic = 0,
    [int]     $Board = 0,
    [int[]]   $Queue = @(),
    [int]     $Issue = 0,
    [string]  $Note = "",
    [string]  $Next = "",
    [string]  $Repo = "",
    [string]  $TokenVar = "GITHUB_TOKEN_PERSONAL",
    [switch]  $DryRun
)

# ==============================================================================
# Pure helpers (unit-testable; no gh/git/network, no side effects)
# ==============================================================================

# The comment marker that identifies OUR run-ledger comment on the epic, so update
# can find-and-edit it instead of piling up new comments (same idea as the handoff
# marker in Board-Handoff.ps1).
$script:RunLedgerMarker = "<!-- abios-run-ledger -->"

# RFC3339 UTC (always Z). Takes a DateTime so tests are deterministic.
function Get-RunLedgerStamp([datetime]$when) {
    return $when.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

# Build a fresh run-state object. Pure: the caller passes the clock.
function New-RunState {
    param(
        [int]     $Epic,
        [int]     $Board,
        [string]  $Repo,
        [int[]]   $Queue = @(),
        [datetime]$When
    )
    return [pscustomobject]@{
        epic    = $Epic
        board   = $Board
        repo    = $Repo
        status  = 'active'
        started = Get-RunLedgerStamp $When
        updated = Get-RunLedgerStamp $When
        queue   = @($Queue)
        entries = @()
    }
}

# Append one progress entry to a run-state and bump `updated`. Returns a NEW object
# (does not mutate the input) so tests can assert on both. Idempotent-friendly:
# re-recording the same issue appends a new row (the ledger is a log, not a set).
function Add-RunEntry {
    param(
        [Parameter(Mandatory)]$State,
        [int]     $Issue,
        [string]  $Note = "",
        [string]  $Next = "",
        [datetime]$When
    )
    $entry = [pscustomobject]@{
        issue = $Issue
        note  = ([string]$Note).Trim()
        next  = ([string]$Next).Trim()
        at    = Get-RunLedgerStamp $When
    }
    $entries = @($State.entries) + $entry
    return [pscustomobject]@{
        epic    = $State.epic
        board   = $State.board
        repo    = $State.repo
        status  = $State.status
        started = $State.started
        updated = Get-RunLedgerStamp $When
        queue   = @($State.queue)
        entries = @($entries)
    }
}

# Render the durable epic comment body from a run-state. Pure. Carries the hidden
# marker (for exact find) and a visible [abios-run-ledger] tag (discovery), then a
# one-row-per-update table of what the board does NOT hold (decision / next step).
function Format-RunLedgerComment {
    param([Parameter(Mandatory)]$State)
    $queue = if (@($State.queue).Count) { (@($State.queue) | ForEach-Object { "#$_" }) -join ', ' } else { '(none listed)' }
    $lines = @(
        $script:RunLedgerMarker
        "**[abios-run-ledger]** live ``/board work`` run — epic #$($State.epic). Board #$($State.board)."
        ""
        "- **Queue:** $queue"
        "- **Status:** $($State.status)"
        ""
    )
    $entries = @($State.entries)
    if ($entries.Count) {
        $lines += "| issue | note | next |"
        $lines += "| --- | --- | --- |"
        foreach ($e in $entries) {
            $note = if ($e.note) { $e.note } else { '—' }
            $next = if ($e.next) { $e.next } else { '—' }
            $lines += "| #$($e.issue) | $note | $next |"
        }
        $lines += ""
    }
    $lines += "_Updated $($State.updated)._"
    return ($lines -join "`n")
}

# ==============================================================================
# Main entry. Dot-source guard: the test harness sets ABIOS_RUNLEDGER_DOTSOURCE to
# load the helpers above without running any of the side-effecting code below.
# ==============================================================================
if ($env:ABIOS_RUNLEDGER_DOTSOURCE) { return }

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

$actions = @($Start, $Update, $Close) | Where-Object { $_ }
if ($actions.Count -ne 1) { throw "Pass exactly one action: -Start, -Update, or -Close." }
if ($Epic -le 0) { throw "Pass -Epic <n> (the epic issue that owns this run's queue)." }

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# -- Resolve repo --------------------------------------------------------------
if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "Could not derive the repo from origin - pass -Repo owner/name." }

# -- Marker path (shared state dir; one per main clone, all worktrees share it) --
$stateDir = Get-AbiosStateDir
if (-not $stateDir) { throw "Not inside a git working tree - cannot resolve the state dir." }
$markerPath = Join-Path $stateDir 'active-run.json'

function Read-RunMarker {
    if (-not (Test-Path $markerPath)) { return $null }
    try { return (Get-Content $markerPath -Raw | ConvertFrom-Json) } catch { return $null }
}
function Write-RunMarker([Parameter(Mandatory)]$State) {
    Set-Content -Path $markerPath -Value ($State | ConvertTo-Json -Depth 6) -Encoding UTF8
}

# -- Durable upsert of the ledger comment on the epic (fail-closed, #316) --------
function Update-RunLedgerComment {
    param([Parameter(Mandatory)][string]$Body)
    # A FAILED read of existing comments must NOT read as "no marker" - that posts a
    # DUPLICATE instead of editing. On a read failure, skip the post (the local marker
    # is already written) rather than risk the duplicate.
    $existingId = $null
    try {
        $comments = Invoke-Gh -GhArgs @('api','--paginate',"repos/$Repo/issues/$Epic/comments?per_page=100") `
                              -What "read the comments of $Repo#$Epic" -Json
        $existingId = (@($comments | Where-Object { $_.body -like "*$script:RunLedgerMarker*" }) | Select-Object -Last 1).id
    } catch {
        Write-Host "  WARN could not read existing comments ($($_.Exception.Message)) - NOT posting to avoid a duplicate. Local marker is saved." -ForegroundColor DarkYellow
        return
    }
    try {
        if ($existingId) {
            $null = Invoke-Gh -GhArgs @('api','--method','PATCH',"repos/$Repo/issues/comments/$existingId",'-F','body=@-') `
                              -StdIn $Body -What "update the run-ledger comment on $Repo#$Epic"
            Write-Host "  OK  Run-ledger comment updated on $Repo#$Epic" -ForegroundColor Green
        } else {
            $null = Invoke-Gh -GhArgs @('issue','comment',"$Epic",'--repo',$Repo,'--body-file','-') `
                              -StdIn $Body -What "post the run-ledger comment on $Repo#$Epic"
            Write-Host "  OK  Run-ledger comment posted on $Repo#$Epic" -ForegroundColor Green
        }
    } catch {
        Write-Host "  WARN could not upsert the run-ledger comment ($($_.Exception.Message)) - the local marker is still written." -ForegroundColor DarkYellow
    }
}

$now = Get-Date

# ------------------------------------------------------------------- START -----
if ($Start) {
    if ($Board -le 0) {
        try {
            $owner = ($Repo -split '/')[0]
            $resolved = & (Join-Path $PSScriptRoot "Resolve-Board.ps1") -Owner $owner -Repo $Repo -CreateIfMissing:$false 2>$null
            if ($resolved) { $Board = [int]($resolved | Select-Object -Last 1) }
        } catch { $Board = 0 }
    }
    $state = New-RunState -Epic $Epic -Board $Board -Repo $Repo -Queue $Queue -When $now
    $body  = Format-RunLedgerComment $state
    Write-Host "=== /board run-ledger start  ($Repo)  epic #$Epic ===" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "DRY-RUN - would write $markerPath and upsert:" -ForegroundColor Yellow
        Write-Host ""; Write-Host $body; return
    }
    Write-RunMarker $state
    Write-Host "  OK  active-run.json written (epic #$Epic, board #$Board, $(@($Queue).Count) queued)" -ForegroundColor Green
    Update-RunLedgerComment -Body $body
    return
}

# ------------------------------------------------------------------ UPDATE -----
if ($Update) {
    $state = Read-RunMarker
    if (-not $state) { throw "No active-run.json marker found - run -Start first." }
    if ([int]$state.epic -ne $Epic) { throw "Marker epic (#$($state.epic)) != -Epic #$Epic. Refusing to cross runs." }
    $state = Add-RunEntry -State $state -Issue $Issue -Note $Note -Next $Next -When $now
    $body  = Format-RunLedgerComment $state
    Write-Host "=== /board run-ledger update  ($Repo)  epic #$Epic  issue #$Issue ===" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "DRY-RUN - would append the entry and upsert:" -ForegroundColor Yellow
        Write-Host ""; Write-Host $body; return
    }
    Write-RunMarker $state
    Write-Host "  OK  active-run.json updated ($(@($state.entries).Count) entries)" -ForegroundColor Green
    Update-RunLedgerComment -Body $body
    return
}

# ------------------------------------------------------------------- CLOSE -----
if ($Close) {
    $state = Read-RunMarker
    if (-not $state) { throw "No active-run.json marker found - nothing to close." }
    if ([int]$state.epic -ne $Epic) { throw "Marker epic (#$($state.epic)) != -Epic #$Epic. Refusing to cross runs." }
    $state.status  = 'closed'
    $state.updated = Get-RunLedgerStamp $now
    $body = Format-RunLedgerComment $state
    Write-Host "=== /board run-ledger close  ($Repo)  epic #$Epic ===" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "DRY-RUN - would mark closed and upsert:" -ForegroundColor Yellow
        Write-Host ""; Write-Host $body; return
    }
    Write-RunMarker $state
    Write-Host "  OK  active-run.json marked closed" -ForegroundColor Green
    Update-RunLedgerComment -Body $body
    return
}
