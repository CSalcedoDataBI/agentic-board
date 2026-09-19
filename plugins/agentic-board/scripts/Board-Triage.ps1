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
      #    Single-repo board: bare number is unambiguous
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 42 -Type Bug -Area scripts -Estimate 3
      #    Multi-repo board: qualify with owner/repo#n or -Repo to avoid number collision (#506)
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 'owner/repo#42' -Type Bug -Area scripts -Estimate 3
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 42 -Repo owner/repo -Type Bug -Area scripts -Estimate 3

      # 2b. Batch (#605): the board is read ONCE for the whole batch, however many issues it lists.
      #     Same values for every issue:
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issues 42,43,44 -Type Bug -Area scripts
      #     Per-issue values from a JSON array [{"issue":42,"type":"Bug","area":"scripts","estimate":3,
      #     "priority":"P2","rationale":"..."}, ...] (only "issue" is required):
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -BatchFile triage.json
      #     Every entry is validated before the first write; a target that cannot be resolved is
      #     reported at the end (with the list to retry) instead of aborting the rest of the batch.

      # 3. Priority — proposal only (prints, writes nothing) unless -ConfirmPriority:
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 'owner/repo#42' -Priority P1 -Rationale 'blocks the release'
      ./Board-Triage.ps1 -Number 13 -Owner CSalcedoDataBI -Issue 'owner/repo#42' -Priority P1 -Rationale '...' -ConfirmPriority
#>
[CmdletBinding()]
param(
  # -ProjectNum is the name every other board script of the suite takes; Apply-FieldPreset got the
  # same alias in #297 and this one was missed (#511). Existing -Number callers are unaffected.
  [Alias('ProjectNum')]
  [int]   $Number     = 13,
  [string]$Owner      = 'CSalcedoDataBI',
  # Accept bare number ("42") or qualified "owner/repo#42"; use -Repo to disambiguate bare numbers
  # on multi-repo boards (#506). Empty string = -Pending / batch-view mode.
  [string]$Issue      = '',
  # Batch (#605): several issues in ONE invocation, so the board is read ONCE instead of once per
  # issue. Refs are bare numbers or 'owner/repo#n', comma- or space-separated (a `pwsh -File`
  # call delivers `-Issues 1,2,3` as the single string "1,2,3"). The -Type/-Area/-Estimate/
  # -Priority/-Rationale given alongside apply to EVERY listed issue.
  [string[]]$Issues   = @(),
  # Batch with per-issue values (#605): a JSON array of
  #   { "issue": 42, "repo": "o/r", "type": "Bug", "area": "scripts", "estimate": 3,
  #     "priority": "P2", "rationale": "..." }
  # (all keys but "issue" optional). A key on an entry beats the same flag on the command line.
  [string]$BatchFile  = '',
  # Explicit repo qualifier. Combined with a bare -Issue number it produces a qualified ref that
  # targets exactly one item even when the same number exists in several repos (#506).
  [string]$Repo       = '',
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

# Parse an issue reference (bare number OR "owner/repo#n") and an optional -Repo qualifier.
# Returns { Repo; Number; Qualified } or throws on invalid/conflicting input.
# Qualified = $true  -> exact match by repo+number (safe on multi-repo boards).
# Qualified = $false -> bare number; caller must detect and refuse ambiguous collisions.
# Pure (#506).
function Resolve-IssueRef {
    param([string]$IssueArg, [string]$ExplicitRepo)

    # Qualified form: "owner/repo#number"
    if ($IssueArg -match '^([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)#(\d+)$') {
        $repo   = $Matches[1]
        $number = [int]$Matches[2]
        if ($ExplicitRepo -and $ExplicitRepo -ne $repo) {
            throw "-Issue qualifies '$repo' but -Repo says '$ExplicitRepo': use one, not both."
        }
        return [pscustomobject]@{ Repo = $repo; Number = $number; Qualified = $true }
    }

    # Bare number form
    if ($IssueArg -match '^\d+$') {
        $number = [int]$IssueArg
        $r      = "$ExplicitRepo".Trim()
        return [pscustomobject]@{ Repo = $r; Number = $number; Qualified = ($r -ne '') }
    }

    throw "-Issue '$IssueArg' is not a valid issue reference. Use a bare number (42) or 'owner/repo#42'."
}

# Find board items matching an issue ref. Returns ALL candidates.
# Qualified ref -> filter by repo+number (unambiguous).
# Bare ref      -> filter by number only; may return >1 if repos collide — caller must refuse.
# Pure (#506).
function Find-TriageItems {
    param(
        [Parameter(Mandatory)][object]  $Ref,
        [Parameter(Mandatory)][object[]]$Items
    )
    if ($Ref.Qualified) {
        return @($Items | Where-Object {
            [int]$_.content.number -eq $Ref.Number -and
            "$($_.content.repository)" -eq $Ref.Repo
        })
    }
    return @($Items | Where-Object { [int]$_.content.number -eq $Ref.Number })
}

# Format an item's canonical reference including its repo for display.
# Without a repo (e.g. DraftIssues) falls back to bare #number. Pure (#506).
function Format-ItemRef {
    param([Parameter(Mandatory)][object]$Item)
    $repo = "$($Item.content.repository)".Trim()
    $num  = [int]$Item.content.number
    if ($repo) { return "$repo#$num" }
    return "#$num"
}

# Flatten the refs given to -Issues into a plain list. `pwsh -File script.ps1 -Issues 1,2,3` hands
# the script the single string "1,2,3", so a comma (or whitespace) inside an element is a separator
# too; without this the batch flag would work from an interactive prompt and break from the launcher.
# Pure (#605).
function ConvertTo-TriageRefList {
    param([string[]]$Refs)
    $out = @()
    foreach ($r in @($Refs)) {
        foreach ($piece in ("$r" -split '[,\s]+')) {
            if ($piece.Trim()) { $out += $piece.Trim() }
        }
    }
    return $out
}

# Build the list of triage targets of ONE invocation (#605): the single -Issue, the -Issues list and
# the -BatchFile entries, each carrying the values to write. The command-line values are the
# DEFAULTS of every target; a key present on a batch-file entry beats them. Returns a plain array of
# { Issue; Repo; Type; Area; Estimate; Priority; Rationale }. Empty = the caller is in -Pending mode.
# Reads -BatchFile when given (the only side effect); throws on a file it cannot use, because a
# batch that silently dropped its entries would report success over untriaged work.
function Get-TriageEntries {
    param(
        [string]   $Issue      = '',
        [string[]] $Issues     = @(),
        [string]   $BatchFile  = '',
        [hashtable]$Defaults   = @{}
    )
    $def = { param($k) if ($Defaults.ContainsKey($k) -and $null -ne $Defaults[$k]) { "$($Defaults[$k])" } else { '' } }
    $mk = {
        param($ref, $repo, $type, $area, $est, $prio, $why)
        [pscustomobject]@{
            Issue = "$ref".Trim(); Repo = "$repo".Trim(); Type = "$type"; Area = "$area"
            Estimate = "$est"; Priority = "$prio"; Rationale = "$why"
        }
    }
    $entries = @()
    $refs = @()
    if ("$Issue".Trim()) { $refs += "$Issue".Trim() }
    $refs += @(ConvertTo-TriageRefList $Issues)
    foreach ($r in $refs) {
        $entries += & $mk $r (& $def 'Repo') (& $def 'Type') (& $def 'Area') (& $def 'Estimate') (& $def 'Priority') (& $def 'Rationale')
    }

    if ("$BatchFile".Trim()) {
        if (-not (Test-Path -LiteralPath $BatchFile)) { throw "-BatchFile '$BatchFile' no existe." }
        $raw = Get-Content -LiteralPath $BatchFile -Raw -Encoding UTF8
        if (-not "$raw".Trim()) { throw "-BatchFile '$BatchFile' esta vacio." }
        try { $rows = @($raw | ConvertFrom-Json) }
        catch { throw "-BatchFile '$BatchFile' no es JSON valido: $($_.Exception.Message)" }
        if (-not $rows.Count) { throw "-BatchFile '$BatchFile' no trae ninguna entrada." }
        $n = 0
        foreach ($row in $rows) {
            $n++
            $prop = { param($name) $p = $row.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
                                   if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { "$($p.Value)" } else { $null } }
            $ref = & $prop 'issue'
            if (-not $ref) { throw "-BatchFile entrada #${n}: falta la clave 'issue'." }
            $pick = { param($name) $v = & $prop $name; if ($null -ne $v) { $v } else { & $def $name } }
            $entries += & $mk $ref (& $pick 'repo') (& $pick 'type') (& $pick 'area') (& $pick 'estimate') (& $pick 'priority') (& $pick 'rationale')
        }
    }
    return @($entries)
}

# Validate ONE target BEFORE anything is written, so a batch with a bad row 40 of 45 is refused
# whole instead of leaving the board half-triaged (#605). Same rules the single-issue path always
# had: an Estimate is numeric, a Priority is P0-P3 and carries its rationale (#306). Returns $null
# when valid, else the message. Pure.
function Test-TriageEntry {
    param([Parameter(Mandatory)][object]$Entry)
    $label = if ($Entry.Repo -and $Entry.Issue -notmatch '#') { "$($Entry.Repo)#$($Entry.Issue)" } else { "$($Entry.Issue)" }
    if ($Entry.Estimate -and ($Entry.Estimate -notmatch '^\d+(\.\d+)?$')) {
        return "${label}: -Estimate debe ser numerico (recibi '$($Entry.Estimate)')."
    }
    if ($Entry.Priority -and ($Entry.Priority -notin @('P0','P1','P2','P3'))) {
        return "${label}: Priority debe ser P0, P1, P2 o P3 (recibi '$($Entry.Priority)')."
    }
    $bad = Test-PriorityRequest -Priority $Entry.Priority -Rationale $Entry.Rationale
    if ($bad) { return "${label}: $bad" }
    try { $null = Resolve-IssueRef -IssueArg $Entry.Issue -ExplicitRepo $Entry.Repo }
    catch { return "${label}: $($_.Exception.Message)" }
    return $null
}

# Dot-source guard: tests set $env:ABIOS_TRIAGE_DOTSOURCE to load the pure helpers only.
if ($env:ABIOS_TRIAGE_DOTSOURCE) { return }

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Side-effecting from here ──────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Board reads that report their own truncation (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

# Early input check — refuse an un-rationalised Priority before any read. Every target of a
# batch is validated HERE, all of them, before the first gh call of ANY kind (board resolution from
# origin included) and before the first write (#605).
$badPriority = Test-PriorityRequest -Priority $Priority -Rationale $Rationale
if ($badPriority) { throw $badPriority }
if ($Estimate -and ($Estimate -notmatch '^\d+(\.\d+)?$')) { throw "-Estimate debe ser numerico (recibi '$Estimate')." }
$entries = @(Get-TriageEntries -Issue $Issue -Issues $Issues -BatchFile $BatchFile -Defaults @{
    Repo = $Repo; Type = $Type; Area = $Area; Estimate = $Estimate; Priority = $Priority; Rationale = $Rationale })
$entryErrors = @($entries | ForEach-Object { Test-TriageEntry $_ } | Where-Object { $_ })
if ($entryErrors.Count) { throw ("Batch rechazado, no escribi nada:`n  " + ($entryErrors -join "`n  ")) }

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
if (-not $entries.Count) {
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
    # Sort by repo then number so multi-repo boards group items by origin repository (#506).
    foreach ($it in ($pend | Sort-Object { "$($_.content.repository)-{0:D10}" -f [int]$_.content.number })) {
        $v    = Get-ItemTriageValues $it
        $gaps = Get-TriageGaps $v
        $cell = { param($n) if ("$($v[$n])".Trim()) { "$n=$($v[$n])" } else { "[$n]" } }
        $prio = if ("$($v['Priority'])".Trim()) { "Priority=$($v['Priority'])" } else { "[Priority?]" }
        # Always include repo so cross-repo items are visible and number collisions obvious (#506).
        $ref  = Format-ItemRef $it
        Write-Host ("  {0,-30} {1}" -f $ref, $it.content.title)
        Write-Host ("        {0}  {1}  {2}  {3}" -f (& $cell 'Type'), (& $cell 'Area'), (& $cell 'Estimate'), $prio) -ForegroundColor $(if ($gaps.Count) { 'DarkYellow' } else { 'DarkGreen' })
    }
    Write-Host ""
    Write-Host "  Evidence (Type/Area/Estimate): el agente los infiere del contenido y los escribe:" -ForegroundColor DarkGray
    Write-Host "    /board triage -Owner $Owner -Issue 'owner/repo#<n>' -Type <t> -Area <a> -Estimate <n>" -ForegroundColor DarkGray
    Write-Host "    /board triage -Owner $Owner -Issue <n> -Repo owner/repo -Type <t> ...  (alternativa)" -ForegroundColor DarkGray
    Write-Host "    (En boards de un solo repo, -Issue <n> bare funciona si no hay colision de numero)" -ForegroundColor DarkGray
    Write-Host "  Priority: el agente PROPONE (con razon) y el usuario confirma — nunca en silencio:" -ForegroundColor DarkGray
    Write-Host "    /board triage -Owner $Owner -Issue 'owner/repo#<n>' -Priority P2 -Rationale '...'  [-ConfirmPriority]" -ForegroundColor DarkGray
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ── Mode 2/3: one or more issues — write evidence fields, propose/confirm Priority ──
# The board was read ONCE above ($items); every target below resolves against that one read (#605).

# Set one field on this item, picking the write flag from the field's type. Fails loud.
function Set-ItemField($item, [string]$name, [string]$value) {
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
    $null = Invoke-Gh -GhArgs $editArgs -What "escribir $name en $(Format-ItemRef $item)" -Retries 3
    Write-Host ("  OK  {0} -> {1}" -f $name, $value) -ForegroundColor Green
    return $true
}

# Triage ONE target against the already-read board. Throws on an unresolvable target; the caller
# decides whether that ends the run (a single -Issue) or is recorded and skipped (a batch).
function Invoke-TriageEntry($entry) {
    $script:TriagePhase = 'resolve'
    # Resolve the ref (bare or qualified) and find the matching board item(s) (#506).
    $issueRef    = Resolve-IssueRef -IssueArg $entry.Issue -ExplicitRepo $entry.Repo
    $itemMatches = Find-TriageItems -Ref $issueRef -Items $items

    if (-not $itemMatches) {
        $refStr = if ($issueRef.Repo) { "$($issueRef.Repo)#$($issueRef.Number)" } else { "#$($issueRef.Number)" }
        throw "El issue $refStr no esta en el board #$Number (agregalo con /board add, o /board fill)."
    }

    if ($itemMatches.Count -gt 1) {
        # Number collision across repos — refuse and list the ambiguous candidates so the operator
        # can qualify the target with 'owner/repo#n' or -Repo (#506 symptom 2).
        $candidateList = ($itemMatches | ForEach-Object {
            "    $(Format-ItemRef $_): $($_.content.title)"
        }) -join "`n"
        throw (
            "Numero ambiguo: #{0} existe en {1} repos del board. Califica el target con 'owner/repo#{0}' o -Repo:`n{2}" -f
            $issueRef.Number, $itemMatches.Count, $candidateList
        )
    }

    $item = $itemMatches[0]
    $script:TriagePhase = 'write'      # from here on a throw is a failed board write, not an unresolvable target
    Write-Host ("=== Triage {0}: {1} ===" -f (Format-ItemRef $item), $item.content.title) -ForegroundColor Cyan

    if ($entry.Type)     { $null = Set-ItemField $item 'Type' $entry.Type }
    if ($entry.Area)     { $null = Set-ItemField $item 'Area' $entry.Area }
    if ($entry.Estimate) { $null = Set-ItemField $item 'Estimate' $entry.Estimate }

    # Priority: propose (print) always; write ONLY with -ConfirmPriority.
    if ($entry.Priority) {
        Write-Host ""
        Write-Host "  Propuesta de Priority (juicio de negocio - requiere confirmacion):" -ForegroundColor Yellow
        Write-Host (Format-PriorityProposal -IssueNum $issueRef.Number -Priority $entry.Priority -Rationale $entry.Rationale)
        if ($ConfirmPriority) {
            $ok = Set-ItemField $item 'Priority' $entry.Priority
            if ($ok -and -not $DryRun) { Write-Host "  OK  Priority confirmada y escrita." -ForegroundColor Green }
        } else {
            Write-Host "  (no escrita) Confirma con -ConfirmPriority, o corrige la propuesta." -ForegroundColor DarkGray
        }
    }

    if (-not $entry.Type -and -not $entry.Area -and -not $entry.Estimate -and -not $entry.Priority) {
        $v = Get-ItemTriageValues $item
        $gaps = Get-TriageGaps $v
        Write-Host ("  Valores actuales: Type=[{0}] Area=[{1}] Estimate=[{2}] Priority=[{3}]" -f $v['Type'], $v['Area'], $v['Estimate'], $v['Priority'])
        if ($gaps.Count) { Write-Host ("  Faltan (evidence): {0}. Pasa -Type/-Area/-Estimate para llenarlos." -f ($gaps -join ', ')) -ForegroundColor DarkYellow }
    }
}

# "Batch" is decided by what the caller ASKED for, not by how many targets it produced: a one-row
# -BatchFile or `-Issues 42` is still a batch and owes the retry list when its target fails.
$batchMode = ("$BatchFile".Trim() -ne '') -or (@(ConvertTo-TriageRefList $Issues).Count -gt 0)
if (-not $batchMode -and $entries.Count -eq 1) {
    # One target: a failure IS the run's failure, exactly as before batching existed.
    Invoke-TriageEntry $entries[0]
} else {
    # A batch: one unresolvable target must not abandon the rest of a 45-issue sweep, and the caller
    # needs the list of what did not get done to resume from (#605). A failed WRITE is different: it
    # is an API/auth/quota failure that every remaining write would repeat (each with its own
    # retries), so the batch stops there and lists everything not yet done.
    $failed = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e   = $entries[$i]
        $ref = if ($e.Repo -and $e.Issue -notmatch '#') { "$($e.Repo)#$($e.Issue)" } else { $e.Issue }
        try { Invoke-TriageEntry $e }
        catch {
            $failed += [pscustomobject]@{ Ref = $ref; Why = $_.Exception.Message }
            Write-Host ("  FALLO {0}: {1}" -f $ref, $_.Exception.Message) -ForegroundColor Red
            if ($script:TriagePhase -eq 'write') {
                Write-Host "  Una escritura fallo: detengo el lote en vez de repetir el mismo fallo en los que quedan." -ForegroundColor Red
                for ($j = $i + 1; $j -lt $entries.Count; $j++) {
                    $r2 = if ($entries[$j].Repo -and $entries[$j].Issue -notmatch '#') { "$($entries[$j].Repo)#$($entries[$j].Issue)" } else { $entries[$j].Issue }
                    $failed += [pscustomobject]@{ Ref = $r2; Why = 'no procesado: el lote se detuvo por el error de escritura' }
                }
                break
            }
        }
    }
    Write-Host ""
    Write-Host ("=== Batch: {0} de {1} issue(s) sin error; el board se leyo 1 vez ===" -f ($entries.Count - $failed.Count), $entries.Count) -ForegroundColor Cyan
    if ($failed.Count) {
        Write-Host "  Pendientes para reintentar:" -ForegroundColor Yellow
        foreach ($f in $failed) { Write-Host ("    {0}  ({1})" -f $f.Ref, $f.Why) -ForegroundColor Yellow }
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit 1
    }
}

Write-Host "Board: $boardUrl" -ForegroundColor Cyan
