<#
.SYNOPSIS
    Detect and fill gaps in a GitHub Projects v2 board.

.DESCRIPTION
    Reads all items from a GitHub Projects v2 board, converts any draft notes
    to real GitHub issues automatically, then detects and fills gaps:
    missing assignees, Status, Priority, Size, and Type.

    Fill rules:
      Drafts    : converted to real issues in $Repo before any other step
      Assignees : if empty, assign the board owner
      Status    : issue CLOSED -> Done
                  issue OPEN + merged PR -> Done
                  issue OPEN + open PR   -> In Review (In Progress if absent)
                  issue OPEN + no PR     -> Backlog
      Priority  : if empty -> P2 Medium
      Size      : if empty -> M
      Type      : if empty -> detect from labels (bug->Bug, docs->Docs,
                  refactor->Refactor, chore->Chore), else Feature

    Linked PRs and Sub-issues progress are system-derived — not writable via API.

    The board owner may be a USER or an ORGANIZATION. The owner type is resolved
    up front (see Get-OwnerType) and the project is queried against the matching
    GraphQL root, so the script never false-reports "no gaps" just because the
    board could not be read under the wrong owner root (issue #86).

.PARAMETER Owner
    GitHub login that owns the project board (user OR organization).
    Defaults to CSalcedoDataBI.

.PARAMETER Repo
    owner/repo string. Issues are created here when converting drafts.

.PARAMETER ProjectNum
    GitHub Projects v2 number (e.g. 1).

.PARAMETER DryRun
    Print the plan without executing any changes.

.PARAMETER Auto
    Execute changes without asking for confirmation.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.
    A pre-set $env:GH_TOKEN is respected and NOT overwritten - so a business
    board works with GITHUB_TOKEN_BUSINESS (same contract as Board-Work.ps1).

.EXAMPLE
    .\Board-Fill.ps1 -Owner CSalcedoDataBI -Repo CSalcedoDataBI/csalcedodatabi.com -ProjectNum 1 -DryRun
    .\Board-Fill.ps1 -Owner CSalcedoDataBI -Repo CSalcedoDataBI/csalcedodatabi.com -ProjectNum 1
    .\Board-Fill.ps1 -Owner CSalcedoDataBI -Repo CSalcedoDataBI/csalcedodatabi.com -ProjectNum 1 -Auto
#>
[CmdletBinding()]
param(
    [string]$Owner      = "CSalcedoDataBI",
    [string]$Repo       = "",
    [int]   $ProjectNum = 13,
    [switch]$DryRun,
    [switch]$Auto,
    [string]$TokenVar   = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# The canonical/legacy option vocabulary (issue #278) — every option lookup below goes
# through it, so one board can satisfy every fill regardless of which vocabulary it uses.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

# Fail closed on the item read (#303): a gh failure mid-scan must THROW, not return an empty
# page that the gap detector then reads as a healthy "no gaps" board (the #86 false-clean).
# Dot-sourced BEFORE the guard so tests loading the functions also get the seam to mock.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# ── Functions (pure + gh helpers; defined before the dot-source guard) ─────────

function Get-OwnerRoot {
    # Pure: map a GraphQL RepositoryOwner __typename to the query root field that
    # exposes projectV2(number:) for that owner. This is the decision point behind
    # issue #86 — the board owner may be a USER or an ORGANIZATION.
    param([string]$OwnerType)
    switch ($OwnerType) {
        'User'         { 'user' }
        'Organization' { 'organization' }
        default        { $null }
    }
}

function Get-OwnerUrlSegment {
    # Pure: the github.com path segment for an owner's projects page.
    # Organizations live under /orgs/<login>, everyone else under /users/<login>.
    param([string]$OwnerType)
    if ($OwnerType -eq 'Organization') { 'orgs' } else { 'users' }
}

function Get-OwnerType {
    # Resolve whether $Owner is a User or an Organization. stderr is NOT suppressed
    # so a real auth/network failure surfaces instead of being mistaken for "owner
    # not found". Returns 'User', 'Organization', or $null (login does not exist).
    param([string]$Owner)
    # -Graphql fails closed on a non-zero exit AND on an exit-0 errors[] body, and surfaces gh's
    # stderr in the throw. A genuinely-missing login returns repositoryOwner=null with no errors[],
    # so it still comes back as $null - only a real failure throws now (#303/#315).
    $ownerQuery = 'query($o:String!) { repositoryOwner(login:$o) { __typename } }'
    $resp = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$ownerQuery",'-F',"o=$Owner") `
                      -What "resolver el tipo de owner '$Owner'" -Graphql
    return $resp.data.repositoryOwner.__typename
}

function Resolve-ProjectV2Node {
    # Resolve a ProjectV2 (+ its single-select fields) by number for a USER- OR
    # ORGANIZATION-owned board. Querying only user(login:) silently returns null
    # for org-owned boards, so the old code reported a healthy "no gaps" board that
    # was really unread (issue #86). We resolve the owner type first, then query
    # the CORRECT root — no expected-error noise, and stderr stays visible so real
    # failures are not hidden.
    param([string]$Owner, [int]$Num, [string]$OwnerType)
    $root = Get-OwnerRoot $OwnerType
    if (-not $root) { return $null }
    # Build the query in a variable first: PowerShell does NOT concatenate a
    # bareword like `query=` with an adjacent `(...)` subexpression, so the inline
    # `-f query=(...)` form would pass a broken argument to gh.
    $query = @'
query($owner:String!, $num:Int!) {
  ROOT(login:$owner) {
    projectV2(number:$num) {
      id
      fields(first:30) {
        nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
}
'@ -replace 'ROOT', $root
    $resp = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$query",'-F',"owner=$Owner",'-F',"num=$Num") `
                      -What "resolver el board #$Num de $Owner" -Graphql
    return $resp.data.$root.projectV2
}

function Get-Field($name) { $allFields | Where-Object { $_.name -eq $name } }
function Get-Opt($field, $optName) { ($field.options | Where-Object { $_.name -eq $optName }).id }

# Resolve a CANONICAL option to whatever the board actually calls it: the canonical
# name first, then its legacy aliases (issue #278). Before this, each lookup hard-coded
# one literal name and the two vocabularies were mixed in one script - Status wanted
# 'Backlog' (canonical) while Priority wanted 'P2 Medium' (GitHub's template), so NO
# board could satisfy both and a board built by this tool could not complete the tool's
# own Priority fill. Returns the matched option (.id/.name) or $null.
function Resolve-Opt($field, [string]$fieldKind, [string]$canonical) {
    if (-not $field) { return $null }
    foreach ($n in (Get-OptionAliases $fieldKind $canonical)) {
        $o = $field.options | Where-Object { $_.name -eq $n } | Select-Object -First 1
        if ($o) { return $o }
    }
    return $null
}

# Accumulate all nodes across GraphQL project-item pages (issue #246: without this the
# scan stopped at items(first:100) and silently skipped issues on boards >100 items).
# Pure w.r.t. its injected fetcher -> unit-testable with a fake page source.
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

function Get-BoardItems($projId) {
    return Get-AllPages {
        param($cursor)
        # Cursor as a GraphQL variable (-f cursor=), not interpolated as after: "$cursor": embedded
        # double-quotes in a native gh.exe arg are not escaped, so gh saw the base64 cursor unquoted
        # and its `==` padding parsed as bare tokens -> parse error on every board >100 items (#329).
        $q = @"
query(`$proj:ID!, `$cursor:String) {
  node(id:`$proj) {
    ... on ProjectV2 {
      items(first:100, after:`$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          fieldValues(first:20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                optionId name
              }
            }
          }
          content {
            __typename
            ... on DraftIssue { title }
            ... on Issue {
              number title state
              labels(first:10) { nodes { name } }
              assignees(first:5) { nodes { login } }
              timelineItems(first:20 itemTypes:[CROSS_REFERENCED_EVENT]) {
                nodes {
                  ... on CrossReferencedEvent {
                    willCloseTarget
                    source { ... on PullRequest { number state merged } }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
"@
        $ghArgs = @('api','graphql','-f',"query=$q",'-F',"proj=$projId")
        if ($cursor) { $ghArgs += @('-f',"cursor=$cursor") }
        $resp  = Invoke-Gh -GhArgs $ghArgs -What "leer los items del board" -Graphql
        $items = $resp.data.node.items
        return @{ nodes = $items.nodes; hasNext = $items.pageInfo.hasNextPage; endCursor = $items.pageInfo.endCursor }
    }
}

# Convert one draft note to a real issue. Extracted so the errors[]-fail-closed behavior is
# unit-testable at the Invoke-Gh seam: -Graphql throws on an exit-0 errors[] body, so a failed
# conversion is a FAIL, never a $null number that still counts as converted (#303/#315).
function Convert-DraftToIssue($draftId, $repoId, $title) {
    $convQuery = '
mutation($itemId:ID!, $repoId:ID!) {
  convertProjectV2DraftIssueItemToIssue(input:{
    itemId: $itemId
    repositoryId: $repoId
  }) {
    item { content { ... on Issue { number } } }
  }
}'
    $result = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$convQuery",'-F',"itemId=$draftId",'-F',"repoId=$repoId") `
                        -What "convertir el draft '$title' a issue" -Graphql
    return $result.data.convertProjectV2DraftIssueItemToIssue.item.content.number
}

# The core gap-fill write. Extracted so the errors[]-fail-closed behavior is unit-testable at the
# seam: updateProjectV2ItemFieldValue can 200 with an errors[] body (stale option id, field
# permissions), so -Graphql throws on that as well as on a non-zero exit - a field that was never
# written is then a FAIL for the caller to count, never a false OK (#303/#315).
function Set-ItemSingleSelectValue($projId, $itemId, $fieldId, $optId) {
    $updItemQuery = '
mutation($proj:ID!,$item:ID!,$field:ID!,$opt:String!) {
  updateProjectV2ItemFieldValue(input:{
    projectId:$proj, itemId:$item, fieldId:$field,
    value:{singleSelectOptionId:$opt}
  }) { projectV2Item { id } }
}'
    $null = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$updItemQuery",'-f',"proj=$projId",'-f',"item=$itemId",'-f',"field=$fieldId",'-f',"opt=$optId") `
                      -What "escribir el valor del campo en el item" -Graphql
}

# Dot-source guard: tests set this to load the functions above without running
# the token check or any gh call (same contract as Board-Work.ps1).
if ($env:ABIOS_BOARDFILL_DOTSOURCE) { return }

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── 0. Token ──────────────────────────────────────────────────────────────────
# Respect a pre-set $env:GH_TOKEN (a business board is reached by exporting
# GITHUB_TOKEN_BUSINESS first) instead of clobbering it with the personal PAT.
if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }
if (-not $Repo) { $Repo = "$Owner/agentic-board" }

$mode = if ($DryRun) { "DRY-RUN" } elseif ($Auto) { "AUTO" } else { "INTERACTIVE" }

# ── 1. Resolve owner type, board URL, project + field IDs ──────────────────────
# The owner may be a USER or an ORGANIZATION — resolve which once, up front, so
# both the board URL (/users/ vs /orgs/) and the project query use the right root.
$ownerType = Get-OwnerType $Owner
$boardUrl  = "https://github.com/$(Get-OwnerUrlSegment $ownerType)/$Owner/projects/$ProjectNum"
Write-Host "=== Board-Fill  Owner=$Owner  Project=#$ProjectNum  Mode=$mode ===" -ForegroundColor Cyan
Write-Host "Board: $boardUrl" -ForegroundColor Cyan
Write-Host ""

$projNode = Resolve-ProjectV2Node -Owner $Owner -Num $ProjectNum -OwnerType $ownerType
# A non-existent project (or a token for the wrong account / missing 'project'
# scope) resolves projectV2 to null, and an unknown owner resolves $ownerType to
# null. Abort loudly instead of sailing on to report a healthy, empty board.
if (-not $projNode -or -not $projNode.id) {
    throw "No pude resolver el board: '$Owner' projectV2 #$ProjectNum no existe (owner tipo '$ownerType'), o el token ($TokenVar) no tiene acceso (revisa cuenta y scope 'project'). Aborto en vez de reportar un board sano."
}
$projectId = $projNode.id
$allFields = $projNode.fields.nodes | Where-Object { $_.name }

# Every option is resolved by its CANONICAL name with a legacy fallback (Resolve-Opt),
# so a canonical board AND a default-template one ('Todo', 'P2 Medium') both fill.
$statusNode = Get-Field "Status"
$statusId   = $statusNode.id
$doneId     = (Resolve-Opt $statusNode "Status" "Done").id
$inProgId   = (Resolve-Opt $statusNode "Status" "In Progress").id
$backlogOpt = Resolve-Opt $statusNode "Status" "Backlog"        # 'Backlog', or a template board's 'Todo'
$backlogId  = $backlogOpt.id
$reviewId   = (Resolve-Opt $statusNode "Status" "In Review").id # optional (from the field preset); falls back to In Progress

$prioNode   = Get-Field "Priority"
$prioId     = $prioNode.id
$prioMedOpt = Resolve-Opt $prioNode "Priority" "P2"             # 'P2', or a template board's 'P2 Medium'
$prioMedId  = $prioMedOpt.id

$sizeNode   = Get-Field "Size"
$sizeId     = $sizeNode.id
$sizeMOpt   = Resolve-Opt $sizeNode "Size" "M"
$sizeMId    = $sizeMOpt.id

$typeNode   = Get-Field "Type"
$typeId     = $typeNode.id

# ── 1.5. Resolve repo ID (needed for draft conversion) ────────────────────────
# repository(owner,name) is owner-type-agnostic (works for user AND org repos).
$repoParts = $Repo -split "/"
$repoOwner = $repoParts[0]
$repoName  = $repoParts[1]

$repoIdQuery = '
query($owner:String!, $name:String!) {
  repository(owner:$owner, name:$name) { id }
}'
$repoData = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$repoIdQuery",'-F',"owner=$repoOwner",'-F',"name=$repoName") `
                      -What "resolver el repo '$Repo'" -Graphql
$repoId = $repoData.data.repository.id
if (-not $repoId) {
    throw "No pude resolver el repo '$Repo' (no existe o el token ($TokenVar) no tiene acceso). Aborto."
}

# ── 3. Convert any drafts to real issues ──────────────────────────────────────
$items  = Get-BoardItems $projectId
$drafts = @($items | Where-Object { $_.content.__typename -eq "DraftIssue" })

if ($drafts.Count -gt 0) {
    Write-Host "$($drafts.Count) draft(s) encontrado(s) — convirtiendo a issues reales en $Repo..." -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "(DRY-RUN: conversion omitida)" -ForegroundColor Gray
        $drafts | ForEach-Object { Write-Host "  [draft] $($_.content.title)" }
        Write-Host ""
    } else {
        $convOk = 0; $convFail = 0
        foreach ($draft in $drafts) {
            $draftId = $draft.id
            $title   = $draft.content.title
            try {
                $num = Convert-DraftToIssue $draftId $repoId $title
                Write-Host "  -> #$num $title" -ForegroundColor DarkCyan
                $convOk++
            } catch {
                Write-Host "  FAIL converting '$title': $_" -ForegroundColor Red
                $convFail++
            }
        }
        Write-Host "Conversion: $convOk OK  $convFail fallos" -ForegroundColor Cyan
        Write-Host ""

        # Re-load items so the converted issues appear with their numbers
        $items = Get-BoardItems $projectId
    }
}

# ── 4. Detect gaps ────────────────────────────────────────────────────────────
$plan = @()

foreach ($item in $items) {
    $c = $item.content
    if ($c.__typename -ne "Issue") { continue }

    $fv = $item.fieldValues.nodes
    $assigneeCount  = $c.assignees.nodes.Count
    $currentStatus  = ($fv | Where-Object { $_.field.name -eq "Status"   }).optionId
    $currentPrio    = ($fv | Where-Object { $_.field.name -eq "Priority" }).optionId
    $currentSize    = ($fv | Where-Object { $_.field.name -eq "Size"     }).optionId
    $currentType    = ($fv | Where-Object { $_.field.name -eq "Type"     }).optionId
    $currentStatusN = ($fv | Where-Object { $_.field.name -eq "Status"   }).name

    # Only CLOSING references count (willCloseTarget). A textual "#<n>" mention in a PR body is
    # also a CROSS_REFERENCED_EVENT — counting those falsely moved untouched issues to Done, and
    # the board's built-in "Done -> close issue" workflow then closed them for real (issue #48).
    $closingRefs = @($c.timelineItems.nodes | Where-Object { $_.willCloseTarget -eq $true })
    $mergedPRs = @($closingRefs.source | Where-Object { $_.merged -eq $true })
    $openPRs   = @($closingRefs.source | Where-Object { $_.state  -eq "OPEN"  })
    $labels    = @($c.labels.nodes.name | Where-Object { $_ } | ForEach-Object { $_.ToLower() })

    $changes = @()

    if ($assigneeCount -eq 0) {
        $changes += [PSCustomObject]@{ Type="assignee"; Display="Assignee vacio -> $Owner" }
    }

    $targetStatus = $null; $targetStatusN = $null
    if     ($c.state -eq "CLOSED"  -and $currentStatus -ne $doneId)  { $targetStatus=$doneId;   $targetStatusN="Done (issue cerrado)" }
    elseif ($mergedPRs.Count -gt 0 -and $currentStatus -ne $doneId)  { $targetStatus=$doneId;   $targetStatusN="Done (PR mergeado)" }
    elseif ($openPRs.Count -gt 0) {
        # An open PR means the change is in review/testing -> In Review (the
        # review-gate stage). Fall back to In Progress on boards without it.
        $prTarget  = if ($reviewId) { $reviewId } else { $inProgId }
        $prTargetN = if ($reviewId) { "In Review (PR abierto)" } else { "In Progress (PR abierto)" }
        if ($currentStatus -ne $prTarget -and $currentStatus -ne $doneId) { $targetStatus=$prTarget; $targetStatusN=$prTargetN }
    }
    elseif (-not $currentStatus -and $backlogId)                       { $targetStatus=$backlogId; $targetStatusN="$($backlogOpt.name) (sin PR)" }
    if ($targetStatus) {
        $changes += [PSCustomObject]@{ Type="single"; FieldId=$statusId; TargetId=$targetStatus; Display="Status [$currentStatusN] -> $targetStatusN" }
    }

    if (-not $currentPrio -and $prioMedId) {
        $changes += [PSCustomObject]@{ Type="single"; FieldId=$prioId; TargetId=$prioMedId; Display="Priority vacio -> $($prioMedOpt.name)" }
    }

    if (-not $currentSize -and $sizeMId) {
        $changes += [PSCustomObject]@{ Type="single"; FieldId=$sizeId; TargetId=$sizeMId; Display="Size vacio -> $($sizeMOpt.name)" }
    }

    if (-not $currentType -and $typeId) {
        $detectedType = "Feature"
        if     ($labels -contains "bug")      { $detectedType = "Bug" }
        elseif ($labels -contains "docs")     { $detectedType = "Docs" }
        elseif ($labels -contains "refactor") { $detectedType = "Refactor" }
        elseif ($labels -contains "chore")    { $detectedType = "Chore" }
        $typeOptId = Get-Opt $typeNode $detectedType
        if ($typeOptId) {
            $changes += [PSCustomObject]@{ Type="single"; FieldId=$typeId; TargetId=$typeOptId; Display="Type vacio -> $detectedType" }
        }
    }

    if ($changes.Count -gt 0) {
        $plan += [PSCustomObject]@{
            ItemId   = $item.id
            IssueNum = $c.number
            Title    = $c.title
            State    = $c.state
            Changes  = $changes
        }
    }
}

# ── 5. Print plan ─────────────────────────────────────────────────────────────
if ($plan.Count -eq 0) {
    Write-Host "Board completo. Sin gaps detectados." -ForegroundColor Green
    Write-Host "NOTA: Linked PRs y Sub-issues progress son columnas del sistema, no escribibles via API."
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

Write-Host "Plan de cambios:" -ForegroundColor Yellow
foreach ($entry in $plan) {
    Write-Host ""
    Write-Host "  #$($entry.IssueNum) $($entry.Title) [$($entry.State)]" -ForegroundColor Yellow
    foreach ($ch in $entry.Changes) { Write-Host "    -> $($ch.Display)" }
}
Write-Host ""
Write-Host "Total: $($plan.Count) item(s) con gaps." -ForegroundColor Yellow

if ($DryRun) {
    Write-Host ""
    Write-Host "Modo DRY-RUN — ningun cambio ejecutado." -ForegroundColor Gray
    Write-Host "NOTA: Linked PRs y Sub-issues progress son columnas del sistema, no escribibles via API."
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ── 6. Confirm (interactive) ──────────────────────────────────────────────────
if (-not $Auto) {
    Write-Host ""
    $confirm = Read-Host "Aplicar estos cambios? (s/n)"
    if ($confirm -notmatch '^[sySY]') { Write-Host "Cancelado." -ForegroundColor Gray; exit 0 }
}

# ── 7. Execute ────────────────────────────────────────────────────────────────
$ok = 0; $fail = 0

foreach ($entry in $plan) {
    foreach ($ch in $entry.Changes) {
        try {
            if ($ch.Type -eq "assignee") {
                # An unchecked write reports "OK" for an assignment that never happened. Invoke-Gh
                # throws on a non-zero exit (caught below -> FAIL, $fail++) so the count is honest.
                $assignUrl = "repos/$Repo/issues/$($entry.IssueNum)/assignees"
                $null = Invoke-Gh -GhArgs @('api',$assignUrl,'-X','POST','-F',"assignees[]=$Owner") `
                                  -What "asignar #$($entry.IssueNum) a $Owner"
                Write-Host "  OK  #$($entry.IssueNum) assignee -> $Owner" -ForegroundColor Green
                $ok++
            }
            elseif ($ch.Type -eq "single") {
                Set-ItemSingleSelectValue $projectId $entry.ItemId $ch.FieldId $ch.TargetId
                Write-Host "  OK  #$($entry.IssueNum) $($ch.Display)" -ForegroundColor Green
                $ok++
            }
        } catch {
            Write-Host "  FAIL #$($entry.IssueNum): $_" -ForegroundColor Red
            $fail++
        }
    }
}

Write-Host ""
Write-Host "=== Completado: $ok OK  $fail fallos ===" -ForegroundColor Cyan
Write-Host "NOTA: Linked PRs y Sub-issues progress son columnas del sistema, no escribibles via API."
Write-Host ""
Write-Host "Board: $boardUrl" -ForegroundColor Cyan
