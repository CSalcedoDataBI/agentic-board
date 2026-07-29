<#  Assert-BoardComplete.ps1 — the pass/fail check for "the board is fully worked" (no pending items).

    A runnable gate that answers one question: does board <ProjectNum> still have any PENDING work?
    "Pending" is the SAME definition /board work uses to list what to start (Board-Work.ps1
    `Test-Pending`): an item with no Status yet, or whose Status MEANS Backlog (canonical, or a legacy
    name like GitHub's template 'Todo'). Items In Progress / In Review / Done / Blocked are NOT pending
    — they have been picked up.

    Exit 0  -> the board is CLEAR (0 pending): everything has been started or shipped.
    Exit 1  -> pending items remain (they are listed).

    Requires $env:GH_TOKEN (via the gh-account skill). Run it after a /board work sweep to prove the
    queue is empty, or in CI to assert a milestone board reached zero-pending.

    Usage:
      ./Assert-BoardComplete.ps1 -ProjectNum 13 -Owner CSalcedoDataBI
      ./Assert-BoardComplete.ps1 -ProjectNum 13 -Json
#>
[CmdletBinding()]
param(
    [int]   $ProjectNum = 13,
    [string]$Owner      = 'CSalcedoDataBI',
    [string]$TokenVar   = 'GITHUB_TOKEN_PERSONAL',
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

# The canonical/legacy Status vocabulary — pure at load, so 'Todo' is understood as 'Backlog'.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

# ── Pure helpers (unit-testable; no gh) ───────────────────────────────────────

# Is ONE board item pending? Mirrors Board-Work.ps1 `Test-Pending` exactly (kept in sync via
# Get-CanonicalOptionName, the single vocabulary source): no Status yet, or Status means Backlog.
function Test-BoardItemPending($item) {
    if (-not $item.status) { return $true }
    (Get-CanonicalOptionName 'Status' $item.status) -eq 'Backlog'
}

# Reduce a board's items to a completion verdict. Pure -> the pass/fail logic is testable with plain
# objects, no live board. Returns { Complete; PendingCount; Pending } where Pending is the offending
# items (number + title + status) so a failure is actionable, sorted by issue number.
function Get-BoardCompletion {
    param([object[]]$Items)
    $pending = @(@($Items) | Where-Object { Test-BoardItemPending $_ } | ForEach-Object {
        [pscustomobject]@{
            number = $(if ($_.content) { $_.content.number } else { $_.number })
            title  = $(if ($_.content) { $_.content.title } else { $_.title })
            status = "$($_.status)"
        }
    } | Sort-Object { [int]("0" + "$($_.number)") })
    [pscustomobject]@{
        Complete     = ($pending.Count -eq 0)
        PendingCount = $pending.Count
        Pending      = $pending
    }
}

# Dot-source guard: tests set $env:ABIOS_BOARDCOMPLETE_DOTSOURCE to load the pure helpers only.
if ($env:ABIOS_BOARDCOMPLETE_DOTSOURCE) { return }

# ── Side-effecting from here ──────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Board reads that report their own truncation (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, 'User') }
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# Fail closed: a gh error must THROW, never read as an empty board that falsely reports "complete".
$read     = Get-BoardItems -Number $ProjectNum -Owner $Owner `
                           -What "listar los items del board #$ProjectNum de $Owner"
$result   = Get-BoardCompletion -Items $read.Items
$boardUrl = "https://github.com/users/$Owner/projects/$ProjectNum"

# A capped read cannot license a PASS. This gate exists to ASSERT an absence ("0 pendientes"), which
# is exactly the claim a short read cannot support - and CI would read that PASS as ground truth.
# So truncation fails closed: exit 1 with the reason, never a green "el board esta full" (#484).
$truncWarn = Get-BoardTruncationWarning $read
if ($truncWarn -and $result.Complete) {
    if ($Json) {
        [pscustomobject]@{
            complete = $false; pendingCount = $null; truncated = $true
            itemsRead = $read.Read; reason = $truncWarn; board = $boardUrl
        } | ConvertTo-Json -Depth 6
        exit 1
    }
    Write-Host "=== Board complete?  #$ProjectNum de $Owner ===" -ForegroundColor Cyan
    Write-Host "  FAIL  no puedo verificarlo: $truncWarn" -ForegroundColor Red
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 1
}

if ($Json) {
    # `truncated`/`itemsRead` ride on EVERY response, not just the fail-closed one above. A capped
    # read that DID find pending items still falls through to here, and a consumer reading
    # `pendingCount` with no truncation field would take a floor for an exact count (#484).
    [pscustomobject]@{
        complete  = $result.Complete; pendingCount = $result.PendingCount; pending = $result.Pending
        truncated = [bool]$truncWarn;  itemsRead    = $read.Read;           board   = $boardUrl
    } | ConvertTo-Json -Depth 6
    if ($result.Complete) { exit 0 } else { exit 1 }
}

Write-Host "=== Board complete?  #$ProjectNum de $Owner ===" -ForegroundColor Cyan
if ($result.Complete) {
    Write-Host "  PASS  el board esta full: 0 pendientes (todo empezado o terminado)." -ForegroundColor Green
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}
Write-Host ("  FAIL  quedan {0} item(s) pendiente(s):" -f $result.PendingCount) -ForegroundColor Red
# Already failing, so the verdict does not change - but the COUNT does: a capped read makes this
# list a floor, and "quedan 37" would otherwise read as exact.
if ($truncWarn) { Write-Host "  (al menos: $truncWarn)" -ForegroundColor Yellow }
foreach ($p in $result.Pending) {
    Write-Host ("    #{0,-4} {1}  (Status: {2})" -f $p.number, $p.title, $(if ($p.status) { $p.status } else { '(vacio)' })) -ForegroundColor DarkYellow
}
Write-Host "  Empieza los que falten con /board work, o cierralos/muevelos." -ForegroundColor DarkGray
Write-Host "Board: $boardUrl" -ForegroundColor Cyan
exit 1
