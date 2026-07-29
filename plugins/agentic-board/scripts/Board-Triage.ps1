<#  Board-Triage.ps1 — fill an item's TRIAGE fields from evidence, and PROPOSE (never silently
    write) its Priority (#306).

    The board's pending items — the only part anyone plans from — sit blank on Type / Area /
    Estimate / Priority; what little is filled lands in Done, after the work is over. This closes
    that gap WITHOUT a bulk default (a uniformly-filled board looks prioritised without being so):

      - Type / Area / Estimate are EVIDENCE fields. Their values are present in the issue's own
        content (the kind of failure, the files/surface it touches, the size its Scope implies), so
        the agent infers them and this script writes them directly.
      - Priority is a BUSINESS judgement about what hurts THIS week — a signal that is NOT in the
        repo. The agent PROPOSES P0–P3 with a one-line rationale; this script prints the proposal and
        refuses to write it without an explicit -ConfirmPriority. An autonomous guess would produce
        plausible, well-argued priorities that are still the agent's opinion wearing the owner's name.

    Requires $env:GH_TOKEN (via the gh-account skill).

    Modes:
      # 1. Batch view — the pending items and which triage fields are blank (the work-list):
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Pending

      # 2. Write the evidence fields the agent inferred for ONE issue:
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 42 -Type Bug -Area scripts -Estimate 3

      # 3. Priority — proposal only (prints, writes nothing) unless -ConfirmPriority:
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 42 -Priority P1 -Rationale 'blocks the release'
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 42 -Priority P1 -Rationale '...' -ConfirmPriority
#>
[CmdletBinding()]
param(
  [int]   $Number     = 13,
  [string]$Owner      = 'CSalcedoDataBI',
  [int]   $Issue      = 0,
  [switch]$Pending,
  [string]$Type,
  [string]$Area,
  [string]$Estimate,
  [ValidateSet('P0','P1','P2','P3')][string]$Priority,
  [string]$Rationale,
  [switch]$ConfirmPriority,
  [string]$TokenVar   = 'GITHUB_TOKEN_PERSONAL',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# ── Pure helpers (unit-testable; no gh/network) ───────────────────────────────

# The triage fields, split by how they may be written. Evidence fields come straight from the
# issue's content; Priority is the business judgement that must never be written un-confirmed.
$script:TriageEvidenceFields = @('Type', 'Area', 'Estimate')

# Which EVIDENCE fields are still blank on an item, given its current values as a hashtable
# keyed by display name. Priority is deliberately excluded — its blank is filled only through
# the confirmed proposal path, never flagged as a plain gap to backfill. Pure.
function Get-TriageGaps {
    param([hashtable]$Values)
    @($script:TriageEvidenceFields | Where-Object { -not ("$($Values[$_])").Trim() })
}

# Format the one-line Priority proposal so a wrong call is visible and cheap to correct. Pure.
function Format-PriorityProposal {
    param([int]$IssueNum, [string]$Priority, [string]$Rationale)
    "  #{0} -> {1}  —  {2}" -f $IssueNum, $Priority, $Rationale
}

# Validate a Priority write request BEFORE touching the board. A proposal with no rationale is
# refused: the whole point is that the reasoning is shown, so a silent P-value is exactly what
# this issue forbids. Returns $null when valid, else the error message. Pure.
function Test-PriorityRequest {
    param([string]$Priority, [string]$Rationale)
    if (-not $Priority) { return $null }
    if (-not "$Rationale".Trim()) {
        return "-Priority necesita -Rationale: la propuesta debe mostrar su razonamiento (una linea), no un valor a secas."
    }
    return $null
}

# Decide which board this invocation targets (#382). The bug: -Number DEFAULTED to 13 (the tool's
# OWN roadmap board), so an unqualified run (only -Issue) from ANY other repo silently wrote triage
# onto board #13 instead of the current project's — no error, and #13's item title in the header is
# easy to miss. Rule: an EXPLICIT -Number is honored as-is; WITHOUT one the board is resolved from
# the current repo's origin, never a hardcoded fallback. Pure — the network resolve happens in the
# caller when ResolveFromOrigin is $true. #303 class (a foreign write must never be silent).
function Get-TriageBoardPlan {
    param(
        [bool]  $ExplicitNumber,
        [bool]  $ExplicitOwner,
        [int]   $DefaultNumber,
        [string]$DefaultOwner,
        [string]$OriginRepo          # 'owner/name', or '' when origin is unavailable
    )
    if ($ExplicitNumber) {
        return [pscustomobject]@{ ResolveFromOrigin = $false; Owner = $DefaultOwner; Number = $DefaultNumber; Reason = 'explicit -Number' }
    }
    if ("$OriginRepo" -match '^[^/]+/[^/]+$') {
        $owner = if ($ExplicitOwner) { $DefaultOwner } else { ($OriginRepo -split '/')[0] }
        return [pscustomobject]@{ ResolveFromOrigin = $true; Owner = $owner; Number = 0; Reason = "origin $OriginRepo" }
    }
    # No explicit -Number AND no usable origin -> refuse rather than default to the tool's own board.
    return [pscustomobject]@{ ResolveFromOrigin = $false; Owner = $DefaultOwner; Number = 0; Reason = 'no-origin' }
}

# Dot-source guard: tests set $env:ABIOS_TRIAGE_DOTSOURCE to load the pure helpers only.
if ($env:ABIOS_TRIAGE_DOTSOURCE) { return }

# ── Side-effecting from here ──────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Board reads that report their own truncation (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, 'User')
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# Resolve the target board from origin unless -Number was passed explicitly (#382) — never default to
# the tool's own #13 from a foreign repo.
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
$originRepo = ''
try { $originRepo = "$(Get-RepoFromOriginUrl (git remote get-url origin 2>$null))" } catch { $originRepo = '' }
$plan = Get-TriageBoardPlan -ExplicitNumber $PSBoundParameters.ContainsKey('Number') `
                            -ExplicitOwner  $PSBoundParameters.ContainsKey('Owner') `
                            -DefaultNumber  $Number -DefaultOwner $Owner -OriginRepo $originRepo
if ($plan.Reason -eq 'no-origin') {
    throw "No pude derivar el board: no hay -Number explicito ni un remote 'origin' aqui. Pasa -Number <n> -Owner <o>."
}
$Owner = $plan.Owner
if ($plan.ResolveFromOrigin) {
    $resolved = & (Join-Path $PSScriptRoot 'Resolve-Board.ps1') -Owner $Owner -Repo $originRepo -CreateIfMissing $false
    if (-not $resolved) {
        throw "El repo $originRepo no tiene board enlazado que yo pueda leer. Crealo con /board init, o pasa -Number <n> -Owner <o>."
    }
    $Number = [int]$resolved
    Write-Host ("  Board resuelto desde origin ($originRepo): #{0} de {1}" -f $Number, $Owner) -ForegroundColor DarkGray
}

$boardUrl = "https://github.com/users/$Owner/projects/$Number"

# Early input check — refuse an un-rationalised Priority before any read.
$badPriority = Test-PriorityRequest -Priority $Priority -Rationale $Rationale
if ($badPriority) { throw $badPriority }

# Fields (types + option maps) and items, both fail-closed.
$fields = (Invoke-Gh -GhArgs @('project','field-list',"$Number",'--owner',$Owner,'--format','json') `
                     -What "leer los campos del board #$Number" -Json).fields
$proj   = (Invoke-Gh -GhArgs @('project','view',"$Number",'--owner',$Owner,'--format','json') `
                     -What "leer el board #$Number" -Json).id
# A capped read here would print "(no hay items pendientes)" over a board full of untriaged work -
# the same false all-clear /board work shipped (#484). Get-BoardItems reports the cut.
$itemRead = Get-BoardItems -Number $Number -Owner $Owner `
                           -What "listar los items del board #$Number"
$items    = $itemRead.Items

function Get-FieldDef([string]$name) { $fields | Where-Object { $_.name -eq $name } | Select-Object -First 1 }
function Get-FieldKey([string]$name) { ($name -replace '[^A-Za-z0-9]','').ToLower() }   # how item-list surfaces the value

# Read one item's current triage values into a display-name-keyed hashtable.
function Get-ItemTriageValues($item) {
    $h = @{}
    foreach ($f in @('Type','Area','Estimate','Priority')) { $h[$f] = "$($item.($(Get-FieldKey $f)))" }
    return $h
}

# ── Mode 1: batch view of the pending items and their triage gaps ─────────────
if ($Issue -le 0) {
    $pendingStatuses = @('Backlog', 'In Progress', 'Todo', 'To Do')   # legacy names included
    $pend = @($items | Where-Object { $pendingStatuses -contains "$($_.status)" -and $_.content.number })
    Write-Host "=== Triage: pendientes del board #$Number de $Owner ===" -ForegroundColor Cyan
    $itemTrunc = Get-BoardTruncationWarning $itemRead
    if (-not $pend.Count) {
        # Zero matches inside a partial list is no evidence of zero matches on the board (#484).
        if ($itemTrunc) { Write-Host "  $itemTrunc" -ForegroundColor Yellow }
        else            { Write-Host "  (no hay items pendientes)" -ForegroundColor DarkGray }
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit $(if ($itemTrunc) { 1 } else { 0 })
    }
    if ($itemTrunc) { Write-Host "  $itemTrunc" -ForegroundColor Yellow }
    Write-Host ("  {0}{1} item(s) pendiente(s). Faltantes marcados con []." -f $pend.Count, $(if ($itemTrunc) { '+' } else { '' })) -ForegroundColor DarkGray
    Write-Host ""
    foreach ($it in ($pend | Sort-Object { [int]$_.content.number })) {
        $v    = Get-ItemTriageValues $it
        $gaps = Get-TriageGaps $v
        $cell = { param($n) if ("$($v[$n])".Trim()) { "$n=$($v[$n])" } else { "[$n]" } }
        $prio = if ("$($v['Priority'])".Trim()) { "Priority=$($v['Priority'])" } else { "[Priority?]" }
        Write-Host ("  #{0,-4} {1}" -f $it.content.number, $it.content.title)
        Write-Host ("        {0}  {1}  {2}  {3}" -f (& $cell 'Type'), (& $cell 'Area'), (& $cell 'Estimate'), $prio) -ForegroundColor $(if ($gaps.Count) { 'DarkYellow' } else { 'DarkGreen' })
    }
    Write-Host ""
    Write-Host "  Evidence (Type/Area/Estimate): el agente los infiere del contenido y los escribe:" -ForegroundColor DarkGray
    Write-Host "    Board-Triage.ps1 -Number $Number -Owner $Owner -Issue <n> -Type <t> -Area <a> -Estimate <n>" -ForegroundColor DarkGray
    Write-Host "  Priority: el agente PROPONE (con razon) y el usuario confirma — nunca en silencio:" -ForegroundColor DarkGray
    Write-Host "    Board-Triage.ps1 -Number $Number -Owner $Owner -Issue <n> -Priority P2 -Rationale '...'  [-ConfirmPriority]" -ForegroundColor DarkGray
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ── Mode 2/3: one issue — write evidence fields, propose/confirm Priority ──────
$item = $items | Where-Object { [int]$_.content.number -eq $Issue } | Select-Object -First 1
if (-not $item) { throw "El issue #$Issue no esta en el board #$Number (agregalo con /board add, o /board fill)." }
Write-Host ("=== Triage #{0}: {1} ===" -f $Issue, $item.content.title) -ForegroundColor Cyan

# Set one field on this item, picking the write flag from the field's type. Fails loud.
function Set-ItemField([string]$name, [string]$value) {
    $fdef = Get-FieldDef $name
    if (-not $fdef) { Write-Host ("  WARN el board no tiene el campo '{0}' - lo omito (aplica /board field apply)." -f $name) -ForegroundColor DarkYellow; return $false }
    if ($DryRun) { Write-Host ("  DRY-RUN: {0} -> {1}" -f $name, $value) -ForegroundColor Yellow; return $true }
    $editArgs = @('project','item-edit','--project-id',$proj,'--id',$item.id,'--field-id',$fdef.id)
    if ($fdef.options) {                                   # single-select: resolve the option id
        $opt = $fdef.options | Where-Object { $_.name -eq $value } | Select-Object -First 1
        if (-not $opt) { Write-Host ("  WARN '{0}' no tiene la opcion '{1}' - la omito." -f $name, $value) -ForegroundColor DarkYellow; return $false }
        $editArgs += @('--single-select-option-id', $opt.id)
    } elseif ($fdef.dataType -eq 'NUMBER' -or $name -eq 'Estimate') {
        $editArgs += @('--number', $value)
    } else {
        $editArgs += @('--text', $value)
    }
    $null = Invoke-Gh -GhArgs $editArgs -What "escribir $name en #$Issue" -Retries 3
    Write-Host ("  OK  {0} -> {1}" -f $name, $value) -ForegroundColor Green
    return $true
}

if ($Estimate -and ($Estimate -notmatch '^\d+(\.\d+)?$')) { throw "-Estimate debe ser numerico (recibi '$Estimate')." }

$wroteEvidence = $false
if ($Type)     { $wroteEvidence = (Set-ItemField 'Type' $Type)     -or $wroteEvidence }
if ($Area)     { $wroteEvidence = (Set-ItemField 'Area' $Area)     -or $wroteEvidence }
if ($Estimate) { $wroteEvidence = (Set-ItemField 'Estimate' $Estimate) -or $wroteEvidence }

# Priority: propose (print) always; write ONLY with -ConfirmPriority.
if ($Priority) {
    Write-Host ""
    Write-Host "  Propuesta de Priority (juicio de negocio - requiere confirmacion):" -ForegroundColor Yellow
    Write-Host (Format-PriorityProposal -IssueNum $Issue -Priority $Priority -Rationale $Rationale)
    if ($ConfirmPriority) {
        $ok = Set-ItemField 'Priority' $Priority
        if ($ok -and -not $DryRun) { Write-Host "  OK  Priority confirmada y escrita." -ForegroundColor Green }
    } else {
        Write-Host "  (no escrita) Confirma con -ConfirmPriority, o corrige la propuesta." -ForegroundColor DarkGray
    }
}

if (-not $Type -and -not $Area -and -not $Estimate -and -not $Priority) {
    $v = Get-ItemTriageValues $item
    $gaps = Get-TriageGaps $v
    Write-Host ("  Valores actuales: Type=[{0}] Area=[{1}] Estimate=[{2}] Priority=[{3}]" -f $v['Type'], $v['Area'], $v['Estimate'], $v['Priority'])
    if ($gaps.Count) { Write-Host ("  Faltan (evidence): {0}. Pasa -Type/-Area/-Estimate para llenarlos." -f ($gaps -join ', ')) -ForegroundColor DarkYellow }
}

Write-Host "Board: $boardUrl" -ForegroundColor Cyan
