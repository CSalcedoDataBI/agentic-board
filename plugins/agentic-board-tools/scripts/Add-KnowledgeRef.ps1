<#  Add-KnowledgeRef.ps1 — add one reference to the project knowledge registry.
    Inits the registry (seeded taxonomy) if absent. Enforces the domain guard
    (declared or -NewDomain) and, for local refs, that the path exists (never invent
    references). Appends the record and regenerates KNOWLEDGE.md.

    The registry is JSON by default, but `-Format yaml` writes `registry.yaml` instead — for a repo
    whose pre-commit allow-list blocks `.json` (on purpose: OAuth `credentials.json` is `.json`) but
    passes `.yaml` (#298). An existing `registry.yaml` is detected and kept automatically. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ref,
    [Parameter(Mandatory)][string]$Domain,
    [string]$Title,
    [ValidateSet('repo','md','folder','url','notebooklm','video','')][string]$Type = '',
    [string]$Note = '',
    [switch]$NewDomain,
    [string]$Root = (Get-Location).Path,
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    # Format for a NEW registry: json (default) or yaml (allow-list-friendly). Ignored when a registry
    # already exists - that file's own extension is kept.
    [ValidateSet('json','yaml','')][string]$Format = '',
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KnowledgeRegistryIo.ps1')
$DefaultDomains = @('PowerBI','Fabric','DAX','TMDL','Power-Query','Vega','Claude-Code','Research')
function Test-IsUrl { param([string]$s) return ($s -match '^(https?)://') }

$dir = Join-Path $Root 'knowledge'
$regPath = Resolve-KnowledgeRegistryPath -Root $Root -Format $Format
if (Test-Path -LiteralPath $regPath) {
    $reg = Read-KnowledgeRegistry -Path $regPath
} else {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $reg = [pscustomobject]@{ version=1; project=(Split-Path $Root -Leaf); domains=$DefaultDomains; references=@() }
}

if ($Domain -notin $reg.domains) {
    if (-not $NewDomain) { throw "Unknown domain '$Domain'. Use -NewDomain, or pick: $($reg.domains -join ', ')" }
    $reg.domains = @($reg.domains) + $Domain
}

$isUrl = Test-IsUrl $Ref
if (-not $isUrl) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Ref))) {
        throw "Local ref does not exist: $Ref (never invent references)"
    }
    # Normalize local refs to a repo-relative path with forward slashes, so absolute paths and
    # Windows separators (docs\cap.md) stay portable and dedup against Invoke-KnowledgeHarvest,
    # which emits the same repo-relative forward-slash form.
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    $refFull  = (Resolve-Path -LiteralPath (Join-Path $Root $Ref)).Path
    $Ref = [System.IO.Path]::GetRelativePath($rootFull, $refFull) -replace '\\','/'
}

if ([string]::IsNullOrEmpty($Type)) {
    if ($isUrl) {
        if     ($Ref -match 'notebooklm\.google\.com')           { $Type = 'notebooklm' }
        elseif ($Ref -match '(youtube\.com|youtu\.be|vimeo\.com)') { $Type = 'video' }
        elseif ($Ref -match 'github\.com/[^/]+/[^/]+/?$')          { $Type = 'repo' }
        else                                                      { $Type = 'url' }
    } else {
        if     (Test-Path -LiteralPath (Join-Path $Root $Ref) -PathType Container) { $Type = 'folder' }
        else   { $Type = 'md' }
    }
}
if ([string]::IsNullOrWhiteSpace($Title)) { $Title = if ($isUrl) { $Ref } else { Split-Path $Ref -Leaf } }

$max = 0
foreach ($r in @($reg.references)) { if ($r.id -match '^kn_(\d+)$' -and [int]$Matches[1] -gt $max) { $max = [int]$Matches[1] } }
$id = 'kn_{0:000}' -f ($max + 1)

$record = [pscustomobject]@{ id=$id; domain=$Domain; type=$Type; title=$Title; ref=$Ref; note=$Note; added=$Date }
$reg.references = @($reg.references) + $record

Write-KnowledgeRegistry -Registry $reg -Path $regPath
& (Join-Path $PSScriptRoot 'Write-KnowledgeTable.ps1') -Root $Root | Out-Null

if ($Json) { $record | ConvertTo-Json -Depth 8 } else { $record }
