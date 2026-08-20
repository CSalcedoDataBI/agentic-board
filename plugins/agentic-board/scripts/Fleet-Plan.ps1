<#
.SYNOPSIS
    Advisory board-lead planner (Phase 3, P3-2) - the "who does what" for the /board work
    fleet.

.DESCRIPTION
    Today the human types the issue numbers for `/board work -Parallel`. This planner reads
    the PENDING issues of a board, resolves their blocked-by dependencies into ordered
    WAVES, and routes each issue to the best available CLI by capability (labels / type /
    size). It EMITS the assignment map (prints it + writes .agentic-board/fleet/plan.json
    + prints the suggested -Parallel command per wave) - it never launches anything. Driving
    the fleet stays the human's call (or a future -Launch flag).

    Routing (first available wins, else claude, else first CLI):
      security/architecture label, size L/XL, or Spike -> claude
      Refactor                                         -> codex  -> claude
      Docs                                             -> antigravity -> copilot -> claude
      Chore / size S/XS                                -> copilot -> antigravity -> claude
      otherwise                                        -> claude

    Pure planner core (routing + waves) sits behind a dot-source guard
    ($env:ABIOS_FLEETPLAN_DOTSOURCE) for unit tests; only the board read + emit touch gh.

.PARAMETER ProjectNum
    GitHub Projects v2 board number. Required to actually read the board.

.PARAMETER Owner
    Board owner. Default CSalcedoDataBI.

.PARAMETER Clis
    Available CLIs (comma-joined or array), e.g. "claude,codex". Default: claude only.

.PARAMETER Json
    Emit the raw plan JSON instead of the formatted view.

.EXAMPLE
    .\Fleet-Plan.ps1 -ProjectNum 13 -Clis claude,codex,antigravity
    .\Fleet-Plan.ps1 -ProjectNum 13 -Json
#>
[CmdletBinding()]
param(
    [int]$ProjectNum = 0,
    [string]$Owner = "CSalcedoDataBI",
    [string]$Repo = "",
    [string[]]$Clis = @(),
    [switch]$Json,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)
$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
# gh must fail closed on the board read (#303/#316): a graphql failure that read as an empty board
# would be written to the plan as "nothing pending" - a misread driving a wrong plan (#86 class).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# ------------------------------------------------------------------ pure planner core
function Split-CsvArg {
    param([string[]]$Tokens)
    $out = @()
    foreach ($t in $Tokens) {
        if ($null -eq $t) { continue }
        foreach ($p in ($t -split ',')) {
            $p = $p.Trim()
            if ($p -ne '' -and $out -notcontains $p) { $out += $p }
        }
    }
    return $out
}

# Route an issue to the best AVAILABLE CLI by capability. Pure -> unit-testable.
function Select-CliForIssue {
    param([object]$Issue, [string[]]$Clis)
    $avail = @(Split-CsvArg $Clis)
    if ($avail.Count -eq 0) { $avail = @('claude') }
    $labels = @($Issue.labels | ForEach-Object { "$_".ToLower() })
    $type   = "$($Issue.type)".ToLower()
    $size   = "$($Issue.size)".ToUpper()

    if (($labels -contains 'security') -or ($labels -contains 'architecture') -or $type -eq 'spike' -or ($size -in @('L','XL'))) {
        $pref = @('claude')
    } elseif ($type -eq 'refactor' -or ($labels -contains 'refactor')) {
        $pref = @('codex','claude')
    } elseif ($type -eq 'docs' -or ($labels -contains 'docs') -or ($labels -contains 'documentation')) {
        # 'antigravity' (agy), not the retired 'gemini' CLI - see Get-CliAdapters (#615).
        $pref = @('antigravity','copilot','claude')
    } elseif ($type -eq 'chore' -or ($size -in @('S','XS'))) {
        $pref = @('copilot','antigravity','claude')
    } else {
        $pref = @('claude')
    }
    foreach ($p in $pref)      { if ($avail -contains $p) { return $p } }
    if ($avail -contains 'claude') { return 'claude' }
    return $avail[0]
}

# Layer issues into dependency waves: wave 1 = issues whose in-set blockers are all placed,
# and so on. Blockers OUTSIDE the pending set are treated as satisfied (already closed). A
# cycle can't be ordered, so the remainder is dumped into a final wave (never hangs). Pure.
function Get-AssignmentWaves {
    param([object[]]$Issues)
    $pending = @($Issues | Where-Object { $null -ne $_ })
    $inSet   = @($pending | ForEach-Object { [int]$_.number })
    $placed  = @{}
    $waves   = @()
    $remaining = @($pending)
    while ($remaining.Count -gt 0) {
        $ready = @($remaining | Where-Object {
            $blockers = @($_.blockedBy | Where-Object { $inSet -contains [int]$_ })
            @($blockers | Where-Object { -not $placed[[int]$_] }).Count -eq 0
        })
        if ($ready.Count -eq 0) {
            # unresolvable (cycle) -> place the rest together so nothing is lost
            $waves += , @($remaining)
            break
        }
        $waves += , @($ready)
        foreach ($r in $ready) { $placed[[int]$r.number] = $true }
        $remaining = @($remaining | Where-Object { -not $placed[[int]$_.number] })
    }
    # Unary comma: without it a single-wave result (an array holding one array) is
    # unwrapped on output and the caller sees the issues, not the waves.
    return , $waves
}

# Combine waves x routing into a flat assignment plan: one {issue,title,cli,wave} per issue.
function New-AssignmentPlan {
    param([object[]]$Issues, [string[]]$Clis)
    $avail = @(Split-CsvArg $Clis)
    if ($avail.Count -eq 0) { $avail = @('claude') }
    $waves = Get-AssignmentWaves $Issues
    $plan  = @()
    for ($w = 0; $w -lt $waves.Count; $w++) {
        foreach ($iss in @($waves[$w])) {
            $plan += [pscustomobject]@{
                issue = [int]$iss.number
                title = $iss.title
                cli   = (Select-CliForIssue $iss $avail)
                wave  = $w + 1
            }
        }
    }
    return $plan
}

# ------------------------------------------------------------- board read + emit (I/O)
# Accumulate all board items across pages (same fix as #246).
function Get-AllPages {
    param([scriptblock]$FetchPage)
    $all = @(); $cursor = $null
    do {
        $page = & $FetchPage $cursor
        if (-not $page) { break }
        $all += @($page.nodes)
        $cursor = $page.endCursor
        $more   = [bool]$page.hasNext
    } while ($more)
    return $all
}

# Read the board's PENDING issues (Status Backlog or empty, OPEN) with labels/size/type,
# and best-effort blocked-by numbers from the issue dependencies API.
function Get-PendingBoardIssues {
    param([string]$Owner, [int]$ProjectNum)
    $nodes = Get-AllPages {
        param($cursor)
        # Cursor as a GraphQL variable (-f cursor=), not interpolated as after: "$cursor": embedded
        # double-quotes in a native gh.exe arg are not escaped, so gh saw the base64 cursor unquoted
        # and its `==` padding parsed as bare tokens -> parse error on every board >100 items (#329).
        $q = @"
query(`$o:String!, `$n:Int!, `$cursor:String) {
  user(login:`$o) {
    projectV2(number:`$n) {
      items(first:100, after:`$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          fieldValues(first:20) {
            nodes { ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2SingleSelectField { name } } name } }
          }
          content {
            __typename
            ... on Issue {
              number title state
              labels(first:15) { nodes { name } }
              repository { nameWithOwner }
            }
          }
        }
      }
    }
  }
}
"@
        $ghArgs = @('api','graphql','-f',"query=$q",'-F',"o=$Owner",'-F',"n=$ProjectNum")
        if ($cursor) { $ghArgs += @('-f',"cursor=$cursor") }
        $resp  = Invoke-Gh -GhArgs $ghArgs -What "leer los items del board #$ProjectNum" -Graphql
        $items = $resp.data.user.projectV2.items
        return @{ nodes = $items.nodes; hasNext = $items.pageInfo.hasNextPage; endCursor = $items.pageInfo.endCursor }
    }

    $out = @()
    foreach ($it in $nodes) {
        if ($it.content.__typename -ne 'Issue' -or $it.content.state -ne 'OPEN') { continue }
        $fields = @{}
        foreach ($fv in @($it.fieldValues.nodes)) { if ($fv.field.name) { $fields[$fv.field.name] = $fv.name } }
        $status = $fields['Status']
        if ($status -and $status -ne 'Backlog') { continue }   # only pending
        $repo = $it.content.repository.nameWithOwner
        $blockedBy = @()
        try {
            $deps = gh api "repos/$repo/issues/$($it.content.number)/dependencies/blocked_by" 2>$null | ConvertFrom-Json
            $blockedBy = @($deps | Where-Object { $_.state -eq 'open' } | ForEach-Object { [int]$_.number })
        } catch { }
        $out += [pscustomobject]@{
            number    = [int]$it.content.number
            title     = $it.content.title
            labels    = @($it.content.labels.nodes.name)
            size      = $fields['Size']
            type      = $fields['Type']
            priority  = $fields['Priority']
            repo      = $repo
            blockedBy = $blockedBy
        }
    }
    return $out
}

function Get-FleetPlanPath {
    $state = Get-AbiosStateDir
    if (-not $state) { return $null }
    $dir = Join-Path $state "fleet"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    return (Join-Path $dir "plan.json")
}

function Write-PlanLedger {
    param([string]$Path, [object[]]$Plan)
    if (-not $Path) { $Path = Get-FleetPlanPath }
    if (-not $Path) { return }
    $json = if (@($Plan).Count -eq 0) { '[]' } else { $Plan | ConvertTo-Json -Depth 6 -AsArray }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Show-Plan {
    param([object[]]$Plan)
    if (-not $Plan -or @($Plan).Count -eq 0) {
        Write-Host "  (no hay issues pendientes que planificar)" -ForegroundColor DarkGray
        return
    }
    $waves = @($Plan | ForEach-Object { $_.wave } | Sort-Object -Unique)
    foreach ($w in $waves) {
        $inWave = @($Plan | Where-Object { $_.wave -eq $w })
        Write-Host ("  Wave {0}:" -f $w) -ForegroundColor Cyan
        foreach ($p in $inWave) {
            Write-Host ("     #{0,-4} -> {1,-8} {2}" -f $p.issue, $p.cli, $p.title) -ForegroundColor Yellow
        }
    }
}

# --- dot-source guard: stop here so unit tests get the pure core with no I/O -----
if ($env:ABIOS_FLEETPLAN_DOTSOURCE) { return }

# ------------------------------------------------------------------------ main entry
if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }
if (-not $env:GH_TOKEN) { throw "$TokenVar no esta en el entorno de usuario (y GH_TOKEN vacio)." }
if ($ProjectNum -le 0) { throw "Especifica -ProjectNum <n> del board." }

$issues = @(Get-PendingBoardIssues $Owner $ProjectNum)
$plan   = @(New-AssignmentPlan $issues $Clis)

if ($Json) { if ($plan.Count -eq 0) { '[]' } else { $plan | ConvertTo-Json -Depth 6 -AsArray }; return }

Write-Host "=== Plan de asignacion del fleet (board #$ProjectNum) ===" -ForegroundColor Cyan
$fleetClis = @(Split-CsvArg $Clis); if ($fleetClis.Count -eq 0) { $fleetClis = @('claude') }
Write-Host ("CLIs disponibles: {0}" -f ($fleetClis -join ', ')) -ForegroundColor DarkGray
Write-Host ""
Show-Plan $plan

$ledger = Get-FleetPlanPath
Write-PlanLedger -Path $ledger -Plan $plan
if ($ledger) { Write-Host "" ; Write-Host ("Plan guardado en: {0}" -f $ledger) -ForegroundColor DarkGray }

# Advisory: the -Parallel command per wave (dependent waves run after the prior merges).
if ($plan.Count -gt 0) {
    Write-Host ""
    Write-Host "Sugerencia (advisory - no se lanza nada):" -ForegroundColor Cyan
    foreach ($w in (@($plan | ForEach-Object { $_.wave } | Sort-Object -Unique))) {
        $nums = @($plan | Where-Object { $_.wave -eq $w } | ForEach-Object { $_.issue })
        Write-Host ("  Wave {0}:  /board work -Parallel {1} -Fleet" -f $w, ($nums -join ',')) -ForegroundColor Gray
    }
    Write-Host "  (corre cada wave cuando la anterior haya mergeado sus PRs)" -ForegroundColor DarkGray
}
