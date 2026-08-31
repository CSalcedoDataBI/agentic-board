<#  Get-KnowledgeInventory.ps1 — read-only inventory of the project knowledge registry.
    Reads knowledge/registry.json under -Root, normalizes it, and computes a health
    report (broken local paths, duplicate refs, orphan domains, missing notes). If the
    registry is absent, returns an empty inventory seeded with the default BI taxonomy.
    Deterministic and side-effect free — every other knowledge-ops unit consumes this. #>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$DefaultDomains = @('PowerBI','Fabric','DAX','TMDL','Power-Query','Vega','Claude-Code','Research')
function Test-IsUrl { param([string]$s) return ($s -match '^(https?)://') }

. (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')
$regPath = Resolve-KnowledgeRegistryPath -Root $Root
if (Test-Path -LiteralPath $regPath) {
    $reg = Read-KnowledgeRegistry -Path $regPath
} else {
    $reg = [pscustomobject]@{ version=1; project=(Split-Path $Root -Leaf); domains=$DefaultDomains; references=@() }
}
$refs = @($reg.references)
$declared = @($reg.domains)

$broken = @(); $missingNotes = @()
foreach ($r in $refs) {
    if (-not (Test-IsUrl $r.ref)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $r.ref))) { $broken += $r.id }
    }
    if ([string]::IsNullOrWhiteSpace([string]$r.note)) { $missingNotes += $r.id }
}
$dups = @($refs | Group-Object ref | Where-Object Count -gt 1 | ForEach-Object { $_.Name })
$used = @($refs | Select-Object -ExpandProperty domain -Unique)
$orphan = @($declared | Where-Object { $_ -notin $used })
$byDomain = @{}; foreach ($g in ($refs | Group-Object domain)) { $byDomain[$g.Name] = $g.Count }

$result = [pscustomobject]@{
    project    = $reg.project
    domains    = $declared
    references = $refs
    health     = [pscustomobject]@{ brokenPaths=$broken; duplicates=$dups; orphanDomains=$orphan; missingNotes=$missingNotes }
    summary    = [pscustomobject]@{ total=$refs.Count; byDomain=$byDomain }
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
