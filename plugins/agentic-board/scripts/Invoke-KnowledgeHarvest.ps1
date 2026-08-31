<#  Invoke-KnowledgeHarvest.ps1 — scan the repo for candidate references (read-only).
    Finds docs/**/*.md files and http(s) markdown links in README/docs, dedups against
    the existing registry, and emits candidates. The skill drives the pick + Add. #>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
# Resolve to an absolute path so relative refs are computed correctly when called with -Root . (the documented usage).
$Root = (Resolve-Path -LiteralPath $Root).Path

$seen = [System.Collections.Generic.HashSet[string]]::new()
. (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')
$regPath = Resolve-KnowledgeRegistryPath -Root $Root
if (Test-Path -LiteralPath $regPath) {
    foreach ($r in @((Read-KnowledgeRegistry -Path $regPath).references)) { [void]$seen.Add([string]$r.ref) }
}
$candidates = [System.Collections.Generic.List[object]]::new()
function Add-Candidate { param($type,$title,$ref)
    if (-not $seen.Add([string]$ref)) { return }   # already in registry or already collected
    $candidates.Add([pscustomobject]@{ type=$type; title=$title; ref=$ref; domain='' })
}

$docsDir = Join-Path $Root 'docs'
if (Test-Path -LiteralPath $docsDir) {
    Get-ChildItem -LiteralPath $docsDir -Recurse -File -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = [System.IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\','/'
        $h = Get-Content -LiteralPath $_.FullName -TotalCount 30 | Where-Object { $_ -match '^#\s+(.+)' } | Select-Object -First 1
        $title = if ($h -match '^#\s+(.+)') { $Matches[1].Trim() } else { $_.BaseName }
        Add-Candidate 'md' $title $rel
    }
}
$scan = @()
if (Test-Path -LiteralPath (Join-Path $Root 'README.md')) { $scan += (Join-Path $Root 'README.md') }
if (Test-Path -LiteralPath $docsDir) { $scan += @(Get-ChildItem -LiteralPath $docsDir -Recurse -File -Filter *.md).FullName }
$linkRx = [regex]'\[([^\]]+)\]\((https?://[^\)\s]+)\)'
foreach ($f in $scan) {
    foreach ($m in $linkRx.Matches((Get-Content -LiteralPath $f -Raw))) {
        Add-Candidate 'url' $m.Groups[1].Value.Trim() $m.Groups[2].Value.Trim()
    }
}
$result = [pscustomobject]@{ count = $candidates.Count; candidates = $candidates }
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
