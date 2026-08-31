<#
.SYNOPSIS
    Apply the label taxonomy preset to a repository (/board labels).

.DESCRIPTION
    Reads presets/labels.json (shipped with the plugin) and creates/updates
    every label with `gh label create --force` - idempotent: existing labels
    get their color/description aligned, missing ones are created, and no
    label is ever deleted.

    The taxonomy is wired to the rest of the suite:
      - bug/docs/refactor/chore are EXACTLY what Board-Fill Type detection reads
      - blocked is what the /board work dependency check reads
      - roadmap/plan/plan-task are what plan tracking uses

.PARAMETER Repo
    owner/name. Default: derived from the current directory's origin remote.

.PARAMETER PresetPath
    Alternative labels.json (same schema) to apply instead of the shipped one.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Apply-LabelPreset.ps1
    .\Apply-LabelPreset.ps1 -Repo CSalcedoDataBI/otro-repo
#>
[CmdletBinding()]
param(
    [string]$Repo = "",
    [string]$PresetPath = "",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

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

if (-not $PresetPath) { $PresetPath = Join-Path $PSScriptRoot "..\presets\labels.json" }
$preset = (Get-Content (Resolve-Path $PresetPath) -Raw | ConvertFrom-Json).labels

Write-Host "=== Apply-LabelPreset  ->  $Repo  ($($preset.Count) labels) ===" -ForegroundColor Cyan
Write-Host ""

$ok = 0; $fail = 0
foreach ($l in $preset) {
    gh label create $l.name --color $l.color --description $l.description --force --repo $Repo 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK    $($l.name)" -ForegroundColor Green
        $ok++
    } else {
        Write-Host "  FAIL  $($l.name)" -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
Write-Host "Labels: $ok OK  $fail fallos (idempotente - nunca borra labels existentes)." -ForegroundColor Cyan
