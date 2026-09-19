<#
.SYNOPSIS
    Is this defect already filed? Search open and recently closed issues BEFORE creating one (#675, #476).

.DESCRIPTION
    The feedback flow (skills/abios-feedback) went straight to `gh issue create`. The same defect was
    filed three times in a row - #654, #658 and #667 are all "Apply-FieldPreset reports the field as
    created when the creation failed", closed as not planned - and #661 was a month-old duplicate of
    #655. Each duplicate costs a triage pass and, when it reaches a release fold, a wrong release note.

    This is the pre-filing check the feedback skill runs first. The matching lives in
    IssueSearch.ps1 (shared with the field scan's recurrence matching, #476): title words by overlap
    coefficient plus a bonus for a shared ANCHOR (script name, Verb-Noun function, -Flag). Same-defect
    rewordings score 0.9+; a DIFFERENT defect in the same script scores about 0.35-0.5 and is shown as
    `related`, never blocking. It is advice for a human to read, not a verdict: a `likely` match is
    shown, and the person (or the agent, with the user) decides whether to add evidence to the
    existing issue instead of filing.

    CLI exit codes (the skill acts on them):
      0  nothing likely - safe to file (related issues, if any, are listed)
      3  probable duplicate(s) found - do NOT file; show them, add evidence to the existing one
      2  the search could not be completed - say so, never treat it as "no duplicates"


.PARAMETER Title
    Title of the report you are about to file.

.PARAMETER Body
    Its body (optional; anchors in it count).

.PARAMETER Repo
    owner/name to search. Default CSalcedoDataBI/agentic-board (the tool's own repo).

.PARAMETER ClosedDays
    Also consider issues closed within this many days. Default 30.

.PARAMETER Json
    Emit the result as JSON instead of text.

.EXAMPLE
    .\Find-DuplicateIssue.ps1 -Title "Apply-FieldPreset reports created when creation failed"
#>
[CmdletBinding()]
param(
    [string]$Title = '',
    [string]$Body = '',
    [string]$Repo = 'CSalcedoDataBI/agentic-board',
    [int]   $ClosedDays = 30,
    [double]$LikelyAt = 0.6,
    [double]$RelatedAt = 0.35,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'IssueSearch.ps1')

# ── CLI ────────────────────────────────────────────────────────────────────────
if (-not $Title.Trim()) { Write-Error 'Falta -Title.'; exit 2 }

# Identity: the personal account, or the agent's inside a braked run - the same single resolver.
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
try {
    $ctx = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner (($Repo -split '/')[0])
    $env:GH_TOKEN = $ctx.token
    $cands = Get-IssueCandidates -Repo $Repo -ClosedDays $ClosedDays
} catch {
    Write-Host "NO SE PUDO BUSCAR duplicados en $Repo : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Eso NO significa 'sin duplicados'. Dilo al usuario antes de crear el issue." -ForegroundColor Red
    exit 2
}

$hits   = @(Find-SimilarIssues -Title $Title -Body $Body -Candidates $cands -LikelyAt $LikelyAt -RelatedAt $RelatedAt)
$likely = @($hits | Where-Object { $_.level -eq 'likely' })

if ($Json) {
    [pscustomobject]@{ repo = $Repo; searched = @($cands).Count; likely = $likely.Count; matches = $hits } | ConvertTo-Json -Depth 5
} else {
    Write-Host ("=== Find-DuplicateIssue  {0}  ({1} issues buscados: abiertos + cerrados en {2} dias) ===" -f $Repo, @($cands).Count, $ClosedDays) -ForegroundColor Cyan
    if ($hits.Count -eq 0) { Write-Host '  Nada parecido: se puede crear el issue.' -ForegroundColor Green }
    foreach ($h in $hits) {
        $tag = if ($h.level -eq 'likely') { 'PROBABLE DUPLICADO' } else { 'relacionado' }
        $st  = if ($h.state -eq 'OPEN') { 'abierto' } else { "cerrado ($($h.stateReason))" }
        $col = if ($h.level -eq 'likely') { 'Red' } else { 'DarkYellow' }
        Write-Host ("  {0,-18} #{1} [{2}] {3:N2}  {4}" -f $tag, $h.number, $st, $h.score, $h.title) -ForegroundColor $col
        Write-Host ("  {0,-18} {1}" -f '', $h.url) -ForegroundColor DarkGray
    }
    if ($likely.Count -gt 0) {
        Write-Host "NO CREES un issue nuevo sin mirar estos: si es el mismo defecto, agrega la evidencia al existente (o reabrelo si esta cerrado)." -ForegroundColor Red
    }
}
if ($likely.Count -gt 0) { exit 3 }
exit 0
