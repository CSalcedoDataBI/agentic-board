<#  Set-BoardField.ps1 — bulk-fill ONE custom field across a board's items by a per-item rule.
    Generalizes the common "fill every column" chore: set a single-select field by a title-prefix
    map, or a text field by a {title} template, or a constant for all items. Idempotent, retries
    transient 5xx (502 Bad Gateway is common at scale), handles single-select vs text automatically.

    Requires $env:GH_TOKEN already set (via the gh-account skill).

    Examples:
      # Text field by template ({title} -> the item's title):
      ./Set-BoardField.ps1 -Number 6 -Owner PAL-Devs -Field Ruta -TextTemplate ".claude/skills/{title}/SKILL.md"

      # Single-select by title-prefix map (JSON; "*" = default/fallback):
      ./Set-BoardField.ps1 -Number 6 -Owner PAL-Devs -Field Categoria `
        -PrefixMap '{"apps-":"apps","model-":"model","agent-":"agent","etl-":"etl","viz-":"viz","shared-":"shared","speckit-":"framework","*":"vendored"}'

      # Constant single-select for every matching item:
      ./Set-BoardField.ps1 -Number 6 -Owner PAL-Devs -Field Status -Value Done

    Notes / gotchas baked in:
      - NEVER name a helper after a PowerShell alias (`cat`=Get-Content, `gc`, `sl`, …) — it shadows
        your function and silently runs the alias. (This script uses verb-prefixed names only.)
      - `gh project item-list --format json` exposes custom fields under a lowercased, stripped key
        (Categoria -> .categoria, "Up to Date" -> .uptodate); used here for idempotent skips.
      - single-select needs `--single-select-option-id`; text needs `--text`. This script picks the
        right one from the field's type.
      - Bulk GraphQL mutations are quoting-fragile in PowerShell; a per-item `item-edit` loop with
        backoff is slower but reliable.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$Number,
  [Parameter(Mandatory)][string]$Owner,
  [Parameter(Mandatory)][string]$Field,           # field DISPLAY name (e.g. Categoria, Ruta, Status)
  [string]$Value,                                  # constant: single-select option NAME, or text
  [string]$TextTemplate,                           # text fields: template with {title} placeholder
  [string]$PrefixMap,                              # single-select: JSON {"prefix-":"OptionName",...,"*":"Default"}
  [string]$Filter = '^[a-z0-9]+(-[a-z0-9]+)*$',    # only items whose title matches (default: skill-name shape; skips long-titled issues)
  [int]$Limit = 0,                                 # 0 = the shared board-read ceiling (Get-BoardItems)
  [switch]$Force                                   # re-set even when the current value already matches
)
$ErrorActionPreference = 'Stop'

# A gh failure on the reads below must THROW, not read as an empty board: an empty $items
# reports a false "set=0" success, and an empty $proj/$fields would drive the item-edit
# writes with a bad project id (#303).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# ...and a CAPPED read silently narrows the sweep: this script claims to fill a field across EVERY
# item, so items past the cap go untouched while the summary reads like a complete pass (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

function Resolve-FieldValue([string]$title) {
  if ($TextTemplate) { return $TextTemplate.Replace('{title}', $title) }
  if ($Value)        { return $Value }
  if ($PrefixMap) {
    $map = $PrefixMap | ConvertFrom-Json
    foreach ($p in $map.PSObject.Properties) {
      if ($p.Name -ne '*' -and $title.StartsWith($p.Name)) { return $p.Value }
    }
    if ($map.PSObject.Properties.Name -contains '*') { return $map.'*' }
  }
  return $null
}

if (-not $env:GH_TOKEN) { Write-Error "GH_TOKEN not set — run the gh-account skill first."; exit 1 }

$proj   = (Invoke-Gh -GhArgs @('project','view',"$Number",'--owner',$Owner,'--format','json') `
                     -What "leer el board #$Number" -Json).id
$fields = (Invoke-Gh -GhArgs @('project','field-list',"$Number",'--owner',$Owner,'--format','json') `
                     -What "leer los campos del board #$Number" -Json).fields
$fdef   = $fields | Where-Object { $_.name -eq $Field }
if (-not $fdef) { Write-Error "Field '$Field' not found on project #$Number (owner $Owner)."; exit 1 }
$isSelect = [bool]$fdef.options
$optById  = @{}; if ($isSelect) { foreach ($o in $fdef.options) { $optById[$o.name] = $o.id } }
$fieldKey = ($Field -replace '[^A-Za-z0-9]','').ToLower()   # how item-list surfaces the value

$itemRead = Get-BoardItems -Number $Number -Owner $Owner -Limit $Limit `
                           -What "listar los items del board #$Number"
$items    = $itemRead.Items
# Say it BEFORE the sweep, not after: the user needs to know the pass was partial while the
# "set=N" summary is still ahead of them, not once it already reads like a full sweep.
if ($itemRead.Truncated) {
  Write-Host (Get-BoardTruncationWarning $itemRead) -ForegroundColor Yellow
  Write-Host "  El barrido de abajo cubre solo esos items - los demas quedan sin tocar. Sube -Limit para cubrirlos." -ForegroundColor Yellow
}
$set=0; $skip=0; $fail=0
foreach ($it in $items) {
  if ($it.title -notmatch $Filter) { $skip++; continue }
  $val = Resolve-FieldValue $it.title
  if (-not $val) { $skip++; continue }
  if (-not $Force -and ($it.$fieldKey -eq $val)) { $skip++; continue }   # idempotent

  $ok = $false
  for ($i=0; $i -lt 4; $i++) {
    if ($isSelect) {
      $oid = $optById[$val]
      if (-not $oid) { Write-Warning "Field '$Field' has no option named '$val' (item '$($it.title)')"; break }
      $null = gh project item-edit --project-id $proj --id $it.id --field-id $fdef.id --single-select-option-id $oid 2>&1
    } else {
      $null = gh project item-edit --project-id $proj --id $it.id --field-id $fdef.id --text $val 2>&1
    }
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Start-Sleep -Milliseconds (500 * ($i + 1))   # backoff for transient 5xx
  }
  if ($ok) { $set++ } else { $fail++; Write-Warning "failed: $($it.title)" }
}
Write-Host "Field '$Field' -> set=$set  skipped=$skip  failed=$fail  (of $($items.Count) items)"
# The summary above is the line a human (or a CI log) reads as "the sweep is done". It cannot say
# that off a capped read: the items past the cap were never even considered, so the pass covered a
# subset while reading like a full one. Repeat it here, after the numbers, and exit non-zero - a
# partial sweep is not a success for a command whose contract is "every item on the board" (#484).
if ($itemRead.Truncated) {
  Write-Warning "BARRIDO PARCIAL: solo lei $($itemRead.Read) items (el tope de lectura), asi que los que estan mas alla NO se tocaron. Sube -Limit y re-corre para cubrirlos."
}

# Post-fill visibility check — the #1 "the tool didn't work" false alarm: the field IS filled but
# the board's VIEW doesn't display that column, so the user sees blanks. GitHub Projects view
# columns are UI-only (no GraphQL mutation exists), so no tool can add them — we can only warn.
try {
  $vq = 'query{ node(id:"' + $proj + '"){ ... on ProjectV2 { views(first:20){ nodes{ name fields(first:50){ nodes{ ... on ProjectV2FieldCommon { name } } } } } } } }'
  $views = (gh api graphql -f query=$vq 2>$null | ConvertFrom-Json).data.node.views.nodes
  $visibleIn = @($views | Where-Object { $_.fields.nodes.name -contains $Field } | ForEach-Object { $_.name })
  if ($views -and $visibleIn.Count -eq 0) {
    Write-Warning "'$Field' is FILLED but NOT shown in ANY view ($((@($views).Count)) view(s) checked)."
    Write-Host   "   -> To SEE it: open the board, click the '+' at the right of the column headers, check '$Field'."
    Write-Host   "      (GitHub view columns are UI-only — no API/tool can add a column to a view.)"
  } elseif ($visibleIn.Count) {
    Write-Host "Visible in view(s): $($visibleIn -join ', ')"
  }
} catch { }

# Reminder about un-fillable system columns, so a blank Assignees/Linked PRs/Sub-issues column on
# DRAFT items is never mistaken for a tool failure.
Write-Host "Note: GitHub system columns (Assignees, Linked pull requests, Sub-issues progress, Milestone, Repository, Labels) are auto-derived from real issues/PRs — they stay blank for draft cards and cannot be filled by any tool."

if ($fail -gt 0) { exit 1 }
# A truncated sweep exits non-zero too: automation asking "did the field get filled across the
# board?" must not read exit 0 over items this run never looked at.
if ($itemRead.Truncated) { exit 1 }
