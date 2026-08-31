<#  Get-BoardItems.ps1 - read EVERY item of a board, or say out loud that it could not (#484).

    Why this exists. `gh project item-list` takes a `--limit` and, on reaching it, returns exactly
    that many items with no warning, no error and exit 0. It also returns them OLDEST-FIRST, so on a
    mature board the first N are dominated by Done work and everything past the cap is invisible.
    Board-Work read with `--limit 200` against a 291-item board and printed:

        Sin pendientes. Todo el board esta en progreso o terminado.

    over 37 real Backlog items. That is not a truncation - it is a confident FALSE ALL-CLEAR, and it
    lands precisely on the mature boards where the stakes are highest.

    This is the same class of defect Invoke-Gh.ps1 exists to kill (#303): a read that fails silently
    and is then consumed as fact. Invoke-Gh made a FAILED read loud; this makes a SHORT one loud.
    The two are complementary and neither substitutes for the other - a truncated read succeeds.

    The contract:
      * the read returns fewer items than the cap  -> complete, Truncated = $false.
      * the read returns exactly the cap           -> possibly short, Truncated = $true. The caller
                                                      must NOT state an absence ("sin pendientes",
                                                      "0 Backlog", "PASS") off a truncated read.
      * gh fails                                   -> Invoke-Gh throws, as always.

    Why assert-under-the-cap rather than cross-check `gh project view`'s items.totalCount. The
    totalCount would give an exact "N of M", but it costs a SECOND request per board - and
    -ListBoards loops over every board of the account, so it doubles the request volume of the one
    command already known to exhaust the rate limit (#414). The cap assertion buys the same
    guarantee - never assert an absence off a possibly-short read - for zero extra requests.

    Why a high ceiling is free: gh pages the underlying GraphQL 100 items at a time, so the request
    count scales with the items that actually exist, not with `--limit`. Reading a 291-item board
    costs 3 requests whether the cap is 200 or 2000. The old 200 bought nothing and cost the truth.

    Pure at load: dot-source it, it defines functions only (no gh, no output).
      . (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

    Usage:
      $read = Get-BoardItems -Number 13 -Owner CSalcedoDataBI
      $warn = Get-BoardTruncationWarning $read
      if ($warn) { Write-Host $warn -ForegroundColor Yellow }
      foreach ($i in $read.Items) { ... }
#>

. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# Well past any realistic board, and free (see the header: cost tracks real items, not the cap).
# Named rather than inlined so every call site shares ONE ceiling - the 200/500/800/1000 spread
# across this repo's scripts is how a cap gets forgotten until it lies.
$script:BoardItemReadLimit = 2000

# Accessor, for the callers that cannot use Get-BoardItems itself. Backup-Board needs gh's RAW
# text (re-serialising a snapshot would reshape it), so it reads with -RawJson and checks the cap
# by hand - but it must check against the SAME ceiling, not a second copy of the number.
function Get-BoardItemReadLimit { return $script:BoardItemReadLimit }

# Read a board's items and report whether the read could have been cut short.
# Returns { Items; Read; Limit; Truncated } - never a bare array, because the caller has to be
# handed the truncation flag alongside the data it would otherwise read as complete.
function Get-BoardItems {
    param(
        [Parameter(Mandatory)][int]   $Number,
        [Parameter(Mandatory)][string]$Owner,
        [int]   $Limit = 0,
        [string]$What
    )
    if ($Limit -le 0) { $Limit = $script:BoardItemReadLimit }
    if (-not $What)   { $What  = "listar los items del board #$Number" }

    # -Json fails closed: a read failure THROWS rather than yielding an empty list the caller
    # would report as "sin pendientes" - the green all-clear over a full board (#278/#303/#314).
    # The Where-Object is load-bearing, not defensive noise: gh emits `[]` for an empty board and
    # `'[]' | ConvertFrom-Json` yields $null - and @($null) is an array of ONE $null, so a plain
    # @(...) would report an empty board as holding 1 item and hand callers a null to iterate.
    $items = @((Invoke-Gh -GhArgs @('project','item-list',"$Number",'--owner',$Owner,
                                    '--format','json','--limit',"$Limit") `
                          -What $What -Json).items | Where-Object { $null -ne $_ })

    [pscustomobject]@{
        Items     = $items
        Read      = $items.Count
        Limit     = $Limit
        # -ge, not -gt: gh stops AT the cap, so "read == cap" IS the truncation signature. A board
        # holding exactly $Limit items reports Truncated anyway - a false alarm that costs a warning,
        # against a false all-clear that costs the user's trust. The asymmetry is deliberate.
        Truncated = ($items.Count -ge $Limit)
    }
}

# The message for a short read. Pure (no gh, no host) so the wording is pinned by tests: this is
# the "no silent caps" line the project requires, and it must name the number actually read.
# Returns $null when the read was complete, so a call site is one `if ($warn)` away from honest.
function Get-BoardTruncationWarning {
    param([Parameter(Mandatory)][object]$Read)
    if (-not $Read.Truncated) { return $null }
    "TRUNCADO: lei $($Read.Read) items, que es el tope de la lectura - puede haber mas que no vi. " +
    "NO puedo afirmar que no queden pendientes; revisa el board directamente."
}
