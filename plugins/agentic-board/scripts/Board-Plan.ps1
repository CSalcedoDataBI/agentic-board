<#
.SYNOPSIS
    Turn a plan into a tracked epic + native sub-issues on the repo board (/board plan).

.DESCRIPTION
    A plan is not done when the markdown is written - a plan is done when it
    is a trackable epic with sub-issues on the board. This script is the
    deterministic half of /board plan (the agent gathers/parses the plan and
    confirms with the user; this script creates everything):

      1. Ensures the 'plan' and 'plan-task' labels exist.
      2. Creates the EPIC issue (label: plan) with the description and a
         task overview.
      3. Reuses Board-Breakdown.ps1 to create one child issue per task
         (label: plan-task) attached as NATIVE sub-issues - the board's
         Sub-issues progress column fills itself as they close.
      4. Resolves the repo's board with Resolve-Board.ps1 (find-or-reuse,
         NEVER a blind duplicate) and adds epic + children to it.

    The created issues enter the normal work flow: /board work -> branch ->
    PR with Closes # -> review gate -> merge.

.PARAMETER Title
    Epic title (e.g. "plan: migrate reports to PBIR"). Mandatory.

.PARAMETER Tasks
    One or more SUBSTANTIAL task titles (tiny steps belong as checkboxes in
    -Description, not as issues). Mandatory.

.PARAMETER Description
    Epic body text: goal, context, links (full blob URLs on PUSHED refs
    only - relative paths render broken in issues). When any of the enriched
    params below is present, -Description is used as the "Goal" section.

.PARAMETER Research
    Enriched item: research / prior-art findings (what exists, what to reuse).

.PARAMETER RoleSeed
    Enriched item: the expert-role objective the /board expert auto-mode adopts.

.PARAMETER Deliverables
    Enriched item: one or more concrete deliverables (rendered as a bullet list).

.PARAMETER TestPlan
    Enriched item: the Definition of Done / test plan (rendered as a bullet list).
    Any omitted enriched section renders a detectable TBD placeholder.

.PARAMETER PriorArt
    The prior-art record (queries run, candidates found with stars/license/
    adoption, and the build / reference / extend decision). Rendered as a
    "## Prior-art gate" section in the epic body. One of -PriorArt or
    -NoPriorArt is REQUIRED - the script throws before creating anything
    if neither is supplied.

.PARAMETER NoPriorArt
    Explicitly skip the prior-art search for genuinely novel work. The skip
    is written into the epic body so the omission is visible, not invisible.

.PARAMETER DescriptionFile
    Path to a plain-text file whose content is used as -Description. Lets agents
    write long plan descriptions (which often contain slash-commands like /board or
    /scan) to a temp file rather than passing them inline, where the tool-layer path
    guard would interpret the slashes as filesystem paths and abort the run (#419).
    When supplied, -Description is ignored.

.PARAMETER ResearchFile
    Path to a plain-text file whose content is used as -Research. Same motivation
    as -DescriptionFile: keeps prose with slashes off the command string (#419).

.PARAMETER PriorArtFile
    Path to a plain-text file whose content is used as -PriorArt. Same motivation
    as -DescriptionFile: keeps prose with slashes off the command string (#419).

.PARAMETER Repo
    owner/name. Default: derived from the current directory's origin remote.

.PARAMETER Owner
    Board owner. Default: the owner part of -Repo.

.PARAMETER ProjectNum
    Board number. Default: resolved via Resolve-Board.ps1 (no duplicate
    creation; warns if the repo has no board yet).

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Board-Plan.ps1 -Title "plan: PBIR migration" -Tasks "inventory reports", "convert themes", "validate rendering" -Description "Goal: ..." -PriorArt "Searched: gh search repos pbir migration ... Decision: build (no existing tool covers PBIR)."

.EXAMPLE
    .\Board-Plan.ps1 -Title "plan: novel internal tooling" -Tasks "task A", "task B" -Description "Goal: ..." -NoPriorArt
#>
[CmdletBinding()]
param(
    [string]$Title = "",
    [string[]]$Tasks = @(),
    [string]$Description = "",
    [string]$Research = "",
    [string]$RoleSeed = "",
    [string[]]$Deliverables = @(),
    [string[]]$TestPlan = @(),
    [string]$PriorArt = "",
    [switch]$NoPriorArt,
    [string]$DescriptionFile = "",
    [string]$ResearchFile = "",
    [string]$PriorArtFile = "",
    [string]$Repo = "",
    [string]$Owner = "",
    [int]   $ProjectNum = 0,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ── Pure core (unit-tested via the dot-source guard) ────────────────────────────
# Format-EnrichedEpicBody renders the four standard items the /board expert auto-mode
# reads: Research/prior-art, Role seed, Deliverables, Test plan (DoD). An omitted section
# renders a detectable TBD placeholder so `auto` can tell an unfilled plan from a filled one.
function Format-EnrichedEpicBody {
    [CmdletBinding()]
    param(
        [string]$Goal = "",
        [string]$Research = "",
        [string]$RoleSeed = "",
        [string[]]$Deliverables = @(),
        [string[]]$TestPlan = @()
    )
    $ph = '_TBD - fill before /board expert auto_'
    $text = { param($s) if ([string]::IsNullOrWhiteSpace($s)) { $ph } else { $s.Trim() } }
    $bullets = {
        param($arr)
        if (-not $arr -or @($arr).Count -eq 0) { $ph }
        else { (@($arr) | ForEach-Object { "- $_" }) -join "`n" }
    }
    @(
        "## Goal",                              (& $text $Goal),          "",
        "## Research / Prior-art",              (& $text $Research),      "",
        "## Expert role (seed)",                (& $text $RoleSeed),      "",
        "## Deliverables",                      (& $bullets $Deliverables), "",
        "## Test plan (Definition of Done)",    (& $bullets $TestPlan)
    ) -join "`n"
}

# Format-PriorArtGateBlock renders the mandatory prior-art section that lands in every epic body.
# With -NoPriorArt the section records the explicit skip so the omission is visible, not silent.
function Format-PriorArtGateBlock {
    [CmdletBinding()]
    param(
        [string]$PriorArt = "",
        [switch]$NoPriorArt
    )
    if ($NoPriorArt) {
        return @(
            "## Prior-art gate",
            "_Skipped with -NoPriorArt — record findings here before merging if possible._"
        ) -join "`n"
    }
    @(
        "## Prior-art gate",
        $PriorArt.Trim()
    ) -join "`n"
}

# Resolve a text parameter from an optional file, falling back to the inline value.
# When filePath is set the file MUST exist (a typo in the path must not silently use
# whatever inline text happens to be present). Returns the inline value unchanged when
# filePath is empty or whitespace-only. Pure: tested without hitting the network or the board.
function Resolve-TextParam([string]$filePath, [string]$inline) {
    if ([string]::IsNullOrWhiteSpace($filePath)) { return $inline }
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Board-Plan: file '$filePath' does not exist."
    }
    return (Get-Content -LiteralPath $filePath -Raw)
}

# Assert-PriorArtPresent enforces the gate: an epic cannot be created without either a
# prior-art block or an explicit -NoPriorArt skip. A silent skip is invisible; a recorded
# skip is auditable. Same shape as the -Rationale requirement in Board-Triage.
function Assert-PriorArtPresent {
    [CmdletBinding()]
    param(
        [string]$PriorArt = "",
        [switch]$NoPriorArt
    )
    if (-not $NoPriorArt -and [string]::IsNullOrWhiteSpace($PriorArt)) {
        throw ("Board-Plan: a prior-art search is required before creating an epic.`n" +
               "Run 'gh search repos <topic>' and pass findings via -PriorArt, " +
               "or use -NoPriorArt to record an explicit skip " +
               "(the skip is written into the epic body so the omission is visible, not silent).")
    }
}

# Dot-source guard: tests set $env:ABIOS_BOARDPLAN_DOTSOURCE to load the pure formatter only.
if ($env:ABIOS_BOARDPLAN_DOTSOURCE) { return }

# Resolve file-backed parameters BEFORE validation so Assert-PriorArtPresent sees the
# file content (#419: inline payloads with slashes trip the tool-layer path guard).
$Description = Resolve-TextParam $DescriptionFile $Description
$Research    = Resolve-TextParam $ResearchFile    $Research
$PriorArt    = Resolve-TextParam $PriorArtFile    $PriorArt

if (-not $Title)                          { throw "Board-Plan: -Title is required." }
if (-not $Tasks -or $Tasks.Count -eq 0)   { throw "Board-Plan: -Tasks is required (one or more task titles)." }
Assert-PriorArtPresent -PriorArt $PriorArt -NoPriorArt:$NoPriorArt

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "No pude derivar el repo del origin - pasa -Repo owner/name." }
if (-not $Owner) { $Owner = ($Repo -split "/")[0] }

Write-Host "=== Board-Plan  '$Title'  ($($Tasks.Count) tareas)  ->  $Repo ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. Labels ──────────────────────────────────────────────────────────────────
gh label create plan      --color 0E8A16 --description "Tracked plan epic"          --force --repo $Repo 2>&1 | Out-Null
gh label create plan-task --color C2E0C6 --description "Child task of a tracked plan" --force --repo $Repo 2>&1 | Out-Null

# ── 2. Epic ────────────────────────────────────────────────────────────────────
$taskOverview = ($Tasks | ForEach-Object { "- $_" }) -join "`n"
$enriched = $Research -or $RoleSeed -or (@($Deliverables).Count -gt 0) -or (@($TestPlan).Count -gt 0)
$body = ""
if ($enriched) {
    # The plan carries the four standard items; -Description becomes the Goal text.
    $body += (Format-EnrichedEpicBody -Goal $Description -Research $Research -RoleSeed $RoleSeed -Deliverables $Deliverables -TestPlan $TestPlan)
    $body += "`n`n"
} elseif ($Description) {
    $body += "$Description`n`n"
}
# Prior-art gate block always lands in the epic body so the build-vs-reference decision is auditable.
$body += (Format-PriorArtGateBlock -PriorArt $PriorArt -NoPriorArt:$NoPriorArt)
$body += "`n`n"
$body += "## Tasks (native sub-issues)`n$taskOverview`n`nCreated by /board plan - work them with /board work."

# Same trap as the children (#281): a failing `gh` does not throw, so without these checks the
# epic printed "OK Epic #0" and the run carried on creating sub-issues under a parent that does
# not exist. Nothing below is meaningful if the epic is not real, so fail here and stop.
$epicUrl = $body | gh issue create --repo $Repo --title $Title --label plan --body-file -
if ($LASTEXITCODE -ne 0) { throw "gh issue create fallo para el epic (exit $LASTEXITCODE) - no se creo nada. Revisa que '$Repo' exista y que el token tenga acceso." }
$epicNum = Get-IssueNumberFromUrl $epicUrl
if ($epicNum -le 0) { throw "gh no devolvio la URL del epic (devolvio '$epicUrl') - no se creo nada." }
Write-Host "  OK  Epic #$epicNum  $Title" -ForegroundColor Green
Write-Host "      $epicUrl" -ForegroundColor DarkCyan

# ── 3. Children as native sub-issues (reuse Board-Breakdown) ──────────────────
& (Join-Path $PSScriptRoot "Board-Breakdown.ps1") -Parent $epicNum -Tasks $Tasks -Repo $Repo -Label "plan-task"

# ── 4. Board: resolve (never duplicate) and register ──────────────────────────
if ($ProjectNum -le 0) {
    $resolved = & (Join-Path $PSScriptRoot "Resolve-Board.ps1") -Owner $Owner -Repo $Repo -CreateIfMissing:$false
    if ($resolved) { $ProjectNum = [int]$resolved }
}
if ($ProjectNum -gt 0) {
    $boardUrl = "https://github.com/users/$Owner/projects/$ProjectNum"
    # Count what actually landed. The old code piped every item-add to Out-Null and then
    # announced "registrados en el board" unconditionally - the same false OK as #0 (#281).
    $added = 0; $addFail = 0
    gh project item-add $ProjectNum --owner $Owner --url $epicUrl 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $added++ } else { $addFail++ }

    # Children too (best-effort - auto-add CI may already cover them)
    $subs = $null
    $subsJson = gh api graphql -f query='
query($o:String!, $r:String!, $n:Int!) {
  repository(owner:$o, name:$r) {
    issue(number:$n) { subIssues(first:50) { nodes { number url } } }
  }
}' -f "o=$(($Repo -split '/')[0])" -f "r=$(($Repo -split '/')[1])" -F "n=$epicNum"
    if ($LASTEXITCODE -eq 0 -and $subsJson) { try { $subs = $subsJson | ConvertFrom-Json } catch { } }
    foreach ($s in @($subs.data.repository.issue.subIssues.nodes)) {
        gh project item-add $ProjectNum --owner $Owner --url $s.url 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $added++ } else { $addFail++ }
    }
    Write-Host ""
    if ($addFail -eq 0) {
        Write-Host "  OK  $added item(s) registrados en el board #$ProjectNum" -ForegroundColor Green
    } else {
        # Say what is true: the issues exist, the board is incomplete.
        Write-Host "  WARN $added item(s) registrados, $addFail fallaron en el board #$ProjectNum" -ForegroundColor DarkYellow
        Write-Host "       Los issues SI se crearon - completa el board con /board fill" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Siguiente: /board fill (Priority/Size/Type) y /board work para empezar la primera tarea." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "  WARN $Repo no tiene board vinculado - crea uno con /board init y agrega el epic con /board add $epicUrl" -ForegroundColor DarkYellow
}
