<#  Export-BoardSnapshot.ps1 - render a Projects board as a Markdown table (a publishable snapshot).
    Requires $env:GH_TOKEN (via gh-account). ASCII-only source.
    Usage: ./Export-BoardSnapshot.ps1 -Number 13 -Owner CSalcedoDataBI -OutFile snapshot.md  #>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$Number,
  [Parameter(Mandatory)][string]$Owner,
  [string]$OutFile
)
$ErrorActionPreference = 'Stop'
# gh fails by exit code only, and a native command exiting non-zero does not throw (#303).
# Unchecked, a 401 made this publish a snapshot reading "0 of 0 tracked items done." - a
# document that looks like a finished board rather than a failed read.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# ...and a CAPPED read is the same failure with a different cause: this document states "N of M
# tracked items done", so a short read publishes a finished-looking board that never existed (#484).
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

$itemLimit = Get-BoardItemReadLimit
$resp  = Invoke-Gh -GhArgs @('project', 'item-list', "$Number", '--owner', $Owner, '--format', 'json', '--limit', "$itemLimit") `
                   -What "leer los items del board #$Number de $Owner" -Json -Retries 2

# -Json covers a non-zero exit, an empty body and an unparseable body - but NOT "parsed
# fine, wrong shape" (an error object like {"message":"Not Found"}, or a gh schema change).
# That case must fail here, because @($null).Count is 1, not 0: `@($resp.items)` on a
# missing property yields a one-element array holding $null, and the report would claim
# "0 of 1 tracked items done" over an empty table - a document that contradicts itself.
# Kept as its own check: Get-BoardItems cannot tell a wrong SHAPE from an empty board, so
# reading through it here would trade this guard for the truncation one instead of adding it.
if (-not $resp.PSObject.Properties['items']) {
    throw "No pude leer los items del board #$Number - gh devolvio JSON sin 'items'."
}
$items = @($resp.items | Where-Object { $null -ne $_ })

# The third way this document can lie: a read that stopped at the cap. The snapshot's headline is
# "N of M tracked items done", so a short read publishes a finished-looking board that never
# existed - the same false document a 401 used to produce, from a call that SUCCEEDED (#484).
if ($items.Count -ge $itemLimit) {
    throw "No publico el snapshot del board #$Number - la lectura se corto en $($items.Count) items (el tope de lectura), asi que el 'N de M' del documento seria falso."
}

$rank  = @{ 'Backlog' = 0; 'In Progress' = 1; 'In Review' = 2; 'Done' = 3 }
$sorted = $items | Sort-Object `
  @{ Expression = { if ($rank.ContainsKey([string]$_.status)) { $rank[[string]$_.status] } else { 9 } } },
  @{ Expression = { $_.content.number } }

$done  = ($items | Where-Object { $_.status -eq 'Done' }).Count
$total = $items.Count

$lines = @()
$lines += "_$done of $total tracked items done._"
$lines += ""
$lines += "| Status | Item | Issue |"
$lines += "|--------|------|-------|"
foreach ($it in $sorted) {
  $s = if ($it.status) { $it.status } else { '-' }
  $t = ($it.title -replace '\|', '\|')
  $n = $it.content.number
  $u = $it.content.url
  $lines += ("| {0} | {1} | [#{2}]({3}) |" -f $s, $t, $n, $u)
}
$out = $lines -join "`n"

if ($OutFile) { $out | Out-File $OutFile -Encoding UTF8; Write-Host "Snapshot written: $OutFile" }
else { $out }
