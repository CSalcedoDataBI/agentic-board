<#
.SYNOPSIS
    Fleet file-ownership guard (Phase 3, P3-3) - "one owner per file" for the parallel
    /board work fleet.

.DESCRIPTION
    Parallel worktrees can edit the same files and collide at merge time. This guard lets
    each fleet session DECLARE the paths it will own for its issue, into a shared registry
    next to the MAIN clone's .git (.agentic-board/fleet/ownership.json, shared across
    worktrees), and warns when a new claim would OVERLAP paths another live session already
    owns. Overlap is boundary-aware: owning a directory ('scripts') conflicts with a file
    inside it ('scripts/Foo.ps1') but not with a look-alike sibling ('scriptsfoo/Bar.ps1').

    Dead sessions release their paths automatically: every read prunes claims whose
    sessionPid is no longer a live process (a pid of 0/unknown is kept). Like sessions.json,
    identity is the long-lived PARENT of this script (the host session), not the transient
    script PID.

    Same conventions as Fleet-Findings.ps1: pure-ASCII source, pure helpers behind a
    dot-source guard ($env:ABIOS_FLEETOWNERSHIP_DOTSOURCE) for unit tests, no gh/token.

.PARAMETER Claim
    Declare ownership of -Paths for -Issue (warns on overlap, then records the claim).

.PARAMETER Check
    Dry check: report overlaps for -Paths without recording. Exit 1 if any overlap, else 0
    (so a session can gate on it before starting).

.PARAMETER List
    Show the live ownership registry (dead-PID claims pruned).

.PARAMETER Release
    Remove -Issue's claim (call when the issue's PR merges).

.PARAMETER Issue
    The issue whose session owns the paths.

.PARAMETER Branch
    The work branch (informational, shown in conflict reports).

.PARAMETER Paths
    Files/dirs to own (comma-joined or a native array; the pwsh -File "a,b" case is split).

.PARAMETER Json
    With -List: emit raw JSON.

.EXAMPLE
    .\Fleet-Ownership.ps1 -Check  -Issue 241 -Paths "plugins/agentic-board/scripts/Board-Work.ps1"
    .\Fleet-Ownership.ps1 -Claim  -Issue 241 -Branch issue-241-x -Paths "scripts/A.ps1,scripts/B.ps1"
    .\Fleet-Ownership.ps1 -List
    .\Fleet-Ownership.ps1 -Release -Issue 241
#>
[CmdletBinding()]
param(
    [switch]$Claim,
    [switch]$Check,
    [switch]$List,
    [switch]$Release,
    [int]$Issue = 0,
    [string]$Branch = "",
    [string[]]$Paths = @(),
    [switch]$Json
)
$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# ------------------------------------------------------------------ pure helpers
# Normalize a path for comparison: forward slashes, no leading ./, no trailing /,
# lowercased (Windows paths are case-insensitive). Pure -> unit-testable.
function ConvertTo-NormPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = ($Path -replace '\\', '/') -replace '^\./', ''
    return $p.TrimEnd('/').ToLower()
}

# Do two paths overlap? Identical, or one is a directory-prefix of the other at a path
# boundary ('src' overlaps 'src/x' but NOT 'srcfoo/x'). Pure -> unit-testable.
function Test-PathOverlap {
    param([string]$A, [string]$B)
    $a = ConvertTo-NormPath $A
    $b = ConvertTo-NormPath $B
    if ($a -eq $b -and $a -ne '') { return $true }
    if ($a -and $b) {
        if ($b.StartsWith("$a/") -or $a.StartsWith("$b/")) { return $true }
    }
    return $false
}

# Build an ownership claim with normalized, de-duplicated, comma-split paths. Pure.
function New-Ownership {
    param(
        [int]$Issue,
        [string]$Branch = "",
        [string[]]$Paths = @(),
        [int]$SessionPid = 0,
        [string]$HostName = "",
        [string]$Now = ""
    )
    $norm = @()
    foreach ($t in $Paths) {
        if ($null -eq $t) { continue }
        foreach ($part in ($t -split ',')) {
            $part = $part.Trim()
            if ($part -eq '') { continue }
            $n = ConvertTo-NormPath $part
            if ($n -ne '' -and $norm -notcontains $n) { $norm += $n }
        }
    }
    [pscustomobject]@{
        issue      = $Issue
        branch     = $Branch
        paths      = @($norm)
        sessionPid = $SessionPid
        host       = $HostName
        ts         = $Now
    }
}

# Conflicts for $NewClaim against $Existing: every OTHER issue whose owned paths overlap
# the new claim's paths, each with the list of overlapping (existing) paths. Pure.
function Find-OwnershipConflicts {
    param([object[]]$Existing, [object]$NewClaim)
    $out = @()
    foreach ($e in @($Existing | Where-Object { $null -ne $_ })) {
        if ([int]$e.issue -eq [int]$NewClaim.issue) { continue }
        $overlap = @()
        foreach ($np in @($NewClaim.paths)) {
            foreach ($ep in @($e.paths)) {
                if ((Test-PathOverlap $np $ep) -and ($overlap -notcontains $ep)) { $overlap += $ep }
            }
        }
        if ($overlap.Count -gt 0) {
            $out += [pscustomobject]@{ issue = [int]$e.issue; branch = $e.branch; paths = @($overlap) }
        }
    }
    return $out
}

# Drop claims whose sessionPid is a dead process. A pid <= 0 (unknown) is KEPT - we can't
# prove it dead. $IsAlive is injected (a pid -> bool predicate) so this stays pure/testable.
function Remove-DeadClaims {
    param([object[]]$Claims, [scriptblock]$IsAlive)
    return @($Claims | Where-Object {
        $null -ne $_ -and ( [int]$_.sessionPid -le 0 -or (& $IsAlive ([int]$_.sessionPid)) )
    })
}

# ------------------------------------------------------------- disk (side-effecting)
# ownership.json next to the MAIN clone's .git, shared across every worktree.
function Get-FleetOwnershipPath {
    $state = Get-AbiosStateDir
    if (-not $state) { return $null }
    $dir = Join-Path $state "fleet"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    return (Join-Path $dir "ownership.json")
}

# Read all claims (empty on missing/corrupt - a guard must never throw). -Path injectable.
function Read-Ownership {
    param([string]$Path)
    if (-not $Path) { $Path = Get-FleetOwnershipPath }
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    try { $data = @(Get-Content $Path -Raw | ConvertFrom-Json) } catch { return @() }
    return @($data | Where-Object { $null -ne $_ } | ForEach-Object {
        $_.paths = @($_.paths | Where-Object { $null -ne $_ })
        $_
    })
}

# Upsert a claim by issue (a re-claim REPLACES that issue's paths - ownership is current,
# not cumulative), written as a JSON array.
function Write-Ownership {
    param([string]$Path, [object]$Claim)
    if (-not $Path) { $Path = Get-FleetOwnershipPath }
    if (-not $Path) { return }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $others = @(Read-Ownership -Path $Path | Where-Object { [int]$_.issue -ne [int]$Claim.issue })
    Set-Content -Path $Path -Value (ConvertTo-OwnershipJson @($others + $Claim)) -Encoding UTF8
}

# Serialize a claim array to a JSON string, always an array even when empty (an empty
# pipeline into ConvertTo-Json emits nothing, which would leave Set-Content a no-op and
# fail to clear the file - so force "[]").
function ConvertTo-OwnershipJson {
    param([object[]]$Claims)
    if (@($Claims).Count -eq 0) { return '[]' }
    return ($Claims | ConvertTo-Json -Depth 6 -AsArray)
}

# Release an issue's claim.
function Remove-OwnershipClaim {
    param([string]$Path, [int]$Issue)
    if (-not $Path) { $Path = Get-FleetOwnershipPath }
    if (-not $Path -or -not (Test-Path $Path)) { return }
    $kept = @(Read-Ownership -Path $Path | Where-Object { [int]$_.issue -ne $Issue })
    Set-Content -Path $Path -Value (ConvertTo-OwnershipJson $kept) -Encoding UTF8
}

# Human-readable render of the live claims.
function Show-Ownership {
    param([object[]]$Claims)
    if (-not $Claims -or @($Claims).Count -eq 0) {
        Write-Host "  (sin claims de propiedad)" -ForegroundColor DarkGray
        return
    }
    foreach ($c in @($Claims | Sort-Object { [int]$_.issue })) {
        Write-Host ("  #{0} {1} (pid {2})" -f $c.issue, $c.branch, $c.sessionPid) -ForegroundColor Yellow
        foreach ($p in @($c.paths)) { Write-Host ("      - {0}" -f $p) -ForegroundColor DarkGray }
    }
}

# --- dot-source guard: stop here so unit tests get the pure helpers with no I/O -----
if ($env:ABIOS_FLEETOWNERSHIP_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
$path    = Get-FleetOwnershipPath
$machine = "$env:COMPUTERNAME"
$alive   = { param($processId) [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue) }

# Prune dead-PID claims on every entry (a crashed session releases its paths).
$existing = @(Read-Ownership -Path $path)
$live     = @(Remove-DeadClaims $existing $alive)
if ($path -and $live.Count -ne $existing.Count) {
    Set-Content -Path $path -Value (ConvertTo-OwnershipJson $live) -Encoding UTF8
}

if ($List) {
    if ($Json) { $live | ConvertTo-Json -Depth 6 -AsArray; return }
    Write-Host "=== Propiedad de archivos del fleet ===" -ForegroundColor Cyan
    Show-Ownership $live
    Write-Host ("Total: {0} claim(s) viva(s)." -f @($live).Count) -ForegroundColor Cyan
    return
}

if ($Issue -le 0) { throw "Especifica -Issue <n> (o usa -List)." }

if ($Release) {
    Remove-OwnershipClaim -Path $path -Issue $Issue
    Write-Host ("  OK  Claim de #{0} liberado." -f $Issue) -ForegroundColor Green
    return
}

# -Claim / -Check both build a prospective claim keyed to the long-lived session PID.
# NOTE: not named $claim - PowerShell vars are case-insensitive, so $claim would alias
# the [switch]$Claim parameter and fail to hold a PSCustomObject (type-constrained).
$trackPid = 0
try { $trackPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch { }
$prospect  = New-Ownership -Issue $Issue -Branch $Branch -Paths $Paths -SessionPid $trackPid -HostName $machine -Now (Get-Date -Format 'yyyy-MM-dd HH:mm')
$conflicts = @(Find-OwnershipConflicts $live $prospect)

if ($conflicts.Count -gt 0) {
    Write-Host ("  WARN #{0} solaparia archivos con otra(s) sesion(es):" -f $Issue) -ForegroundColor Yellow
    foreach ($c in $conflicts) {
        Write-Host ("      #{0} ({1}) ya reclamo: {2}" -f $c.issue, $c.branch, (@($c.paths) -join ', ')) -ForegroundColor Red
    }
} else {
    Write-Host ("  OK  #{0}: sin solapamiento con otras sesiones." -f $Issue) -ForegroundColor Green
}

if ($Check) {
    if ($conflicts.Count -gt 0) { exit 1 } else { exit 0 }
}

if ($Claim) {
    if (-not $Paths -or @($Paths).Count -eq 0) { throw "-Claim requiere -Paths <archivos>." }
    Write-Ownership -Path $path -Claim $prospect
    Write-Host ("  OK  #{0} reclamo {1} archivo(s) en la registry." -f $Issue, @($prospect.paths).Count) -ForegroundColor Green
    if ($path) { Write-Host ("      {0}" -f $path) -ForegroundColor DarkGray }
    return
}

Write-Host "Uso:" -ForegroundColor DarkGray
Write-Host "  ownership del fleet: -Claim  -Issue <n> -Paths <a,b> [-Branch <x>]" -ForegroundColor DarkGray
Write-Host "  ownership del fleet: -Check  -Issue <n> -Paths <a,b>   (exit 1 si hay conflicto)" -ForegroundColor DarkGray
Write-Host "  ownership del fleet: -List [-Json]" -ForegroundColor DarkGray
Write-Host "  ownership del fleet: -Release -Issue <n>" -ForegroundColor DarkGray
