<#  RunLedgerCheckpoint.ps1 - fail-closed auto-checkpoint of the run ledger (#771, fixes #730).

    Dot-source this file (never invoke it), then call Write-RunLedgerCheckpoint right BEFORE a
    side-effecting step of a /board work run (moving an issue to In Progress, launching a
    session, moving to In Review, locking, closing):

        Write-RunLedgerCheckpoint -Step 'start' -Issue 42

    Why. A session that dies without `/board handoff -Save` left nothing behind: the run ledger was
    only written at the three manual touch-points (-Start / -Update / -Close of
    Board-RunLedger.ps1). The checkpoint records, in the local `.agentic-board/active-run.json`
    marker, the step that is ABOUT to run - so the next session knows what was last attempted,
    even when the one that attempted it ended abruptly.

    Why fail closed. A checkpoint that silently failed would let the run keep mutating GitHub/git
    with a ledger that no longer describes it - the exact gap #771 closes. So when a run is active
    and the checkpoint cannot be written, this THROWS and the caller must not take the step.

    Why a no-op otherwise. Ordinary sessions (no marker, or a `closed` run) never get here in any
    meaningful way: no file is created, nothing is written, nothing throws. Only a live run pays.

    Local only: no gh, no network. The durable epic comment stays with Board-RunLedger.ps1
    -Update; a checkpoint per step would turn into one GitHub write per side effect.  #>

# Cap on the checkpoint trail kept in the marker. The marker is a lockfile-sized breadcrumb that
# the offline SessionStart hook reads on every session; an unbounded log would grow it forever.
$script:RunLedgerCheckpointCap = 50

# Atomic write of the marker (temp file + rename), so a crash mid-write cannot leave a half
# written active-run.json that would then fail every later checkpoint closed. A separate
# function so tests can make the writer throw (#771).
function Save-RunLedgerMarker {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    $json = $State | ConvertTo-Json -Depth 8
    $tmp  = "$Path.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $Path, $true)
    } catch {
        try { if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        throw
    }
}

# Record the step about to run in the active run ledger. Returns the checkpoint object written,
# or $null when no run is active (the no-op path). Throws when a run IS active and the
# checkpoint cannot be read or written - the caller must then NOT take the step (#771).
function Write-RunLedgerCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Step,
        [int]     $Issue = 0,
        [string]  $Detail = "",
        # The state dir that holds active-run.json. Omitted: resolved from the current repo via
        # Get-AbiosStateDir -NoCreate (never creates the dir - an ordinary session stays untouched).
        [string]  $StateDir = "",
        [datetime]$When = (Get-Date)
    )
    if (-not $StateDir) {
        if (-not (Get-Command Get-AbiosStateDir -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
        }
        $StateDir = Get-AbiosStateDir -NoCreate
    }
    if (-not $StateDir) { return $null }                       # not in a git repo: no run here
    $path = Join-Path $StateDir 'active-run.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }   # no run: no-op

    $what = if ($Issue -gt 0) { "'$Step' on #$Issue" } else { "'$Step'" }
    try {
        $state = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # A marker exists but cannot be read: a run MAY be active, and we cannot prove the ledger
        # will describe this step. Fail closed rather than guess (#771).
        throw "Run-ledger checkpoint failed before $what - $path is unreadable ($($_.Exception.Message)). Refusing to take the step; fix or close the run (Board-RunLedger.ps1 -Close) first. (#771)"
    }
    if (-not $state -or "$($state.status)" -ne 'active') { return $null }  # closed run: no-op

    $stamp = $When.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $cp = [pscustomobject]@{ step = $Step; issue = $Issue; detail = ([string]$Detail).Trim(); at = $stamp }
    $trail = @()
    if ($state.PSObject.Properties['checkpoints']) { $trail = @($state.checkpoints | Where-Object { $_ }) }
    $trail = @(@($trail) + $cp | Select-Object -Last $script:RunLedgerCheckpointCap)
    if ($state.PSObject.Properties['checkpoints']) { $state.checkpoints = $trail }
    else { $state | Add-Member -NotePropertyName checkpoints -NotePropertyValue $trail }
    if ($state.PSObject.Properties['updated']) { $state.updated = $stamp }

    try {
        Save-RunLedgerMarker -Path $path -State $state
    } catch {
        throw "Run-ledger checkpoint failed before $what - could not write $path ($($_.Exception.Message)). Refusing to take the step so the ledger never lags the run. (#771)"
    }
    return $cp
}
