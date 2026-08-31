<#
.SYNOPSIS
    Install issue forms + PR template into a repository (/board templates).

.DESCRIPTION
    Copies the plugin's template presets into the target repo working copy:

      .github/ISSUE_TEMPLATE/bug.yml       (labels: bug)
      .github/ISSUE_TEMPLATE/feature.yml   (labels: feature)
      .github/ISSUE_TEMPLATE/task.yml      (labels: task)
      .github/ISSUE_TEMPLATE/config.yml
      .github/PULL_REQUEST_TEMPLATE.md     (with the mandatory 'Closes #' slot)

    and ensures the labels the forms reference exist in the GitHub repo
    (a form label that does not exist is silently NOT applied by GitHub).

    Existing files are SKIPPED unless -Force - never silently overwrite a
    repo's customized templates. The script only touches the working copy;
    committing goes through the normal flow (PR when the work is
    board-tracked).

.PARAMETER Path
    Root of the target repo working copy. Default: current directory.
    Must be a git repository.

.PARAMETER Repo
    owner/name for the label creation step. Default: derived from the
    working copy's origin remote.

.PARAMETER Force
    Overwrite files that already exist.

.PARAMETER SkipLabels
    Do not create the labels (e.g. no network / labels managed elsewhere).

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Install-RepoTemplates.ps1                      # current repo
    .\Install-RepoTemplates.ps1 -Path C:\Repos\x -Force
#>
[CmdletBinding()]
param(
    [string]$Path  = ".",
    [string]$Repo  = "",
    [switch]$Force,
    [switch]$SkipLabels,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

$Path = (Resolve-Path $Path).Path
if (-not (Test-Path (Join-Path $Path ".git"))) { throw "$Path no es la raiz de un repo git." }

# Templates ship with the plugin, next to this script
$src = Join-Path $PSScriptRoot "..\presets\templates"
$src = (Resolve-Path $src).Path

# Derive owner/name from origin when not given
if (-not $Repo) {
    $originUrl = git -C $Path remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}

Write-Host "=== Install-RepoTemplates  ->  $Path" -ForegroundColor Cyan
if ($Repo) { Write-Host "    Repo GitHub: $Repo" -ForegroundColor Cyan }
Write-Host ""

$copies = @(
    @{ From = "ISSUE_TEMPLATE\bug.yml";     To = ".github\ISSUE_TEMPLATE\bug.yml" }
    @{ From = "ISSUE_TEMPLATE\feature.yml"; To = ".github\ISSUE_TEMPLATE\feature.yml" }
    @{ From = "ISSUE_TEMPLATE\task.yml";    To = ".github\ISSUE_TEMPLATE\task.yml" }
    @{ From = "ISSUE_TEMPLATE\config.yml";  To = ".github\ISSUE_TEMPLATE\config.yml" }
    @{ From = "PULL_REQUEST_TEMPLATE.md";   To = ".github\PULL_REQUEST_TEMPLATE.md" }
)

$installed = 0; $skipped = 0
foreach ($c in $copies) {
    $from = Join-Path $src  $c.From
    $to   = Join-Path $Path $c.To
    if ((Test-Path $to) -and -not $Force) {
        Write-Host "  SKIP  $($c.To) ya existe (usa -Force para sobreescribir)" -ForegroundColor DarkYellow
        $skipped++
        continue
    }
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item $from $to -Force
    Write-Host "  OK    $($c.To)" -ForegroundColor Green
    $installed++
}

# Labels referenced by the forms MUST exist or GitHub ignores them silently
if (-not $SkipLabels -and $Repo) {
    if (-not $env:GH_TOKEN) {
        $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
    }
    Write-Host ""
    Write-Host "  Asegurando labels de los forms..." -ForegroundColor Cyan
    $labels = @(
        @{ Name = "bug";     Color = "d73a4a"; Desc = "Something is broken" }
        @{ Name = "feature"; Color = "a2eeef"; Desc = "New capability or improvement" }
        @{ Name = "task";    Color = "0e8a16"; Desc = "Concrete work item with a definition of done" }
    )
    foreach ($l in $labels) {
        try {
            gh label create $l.Name --color $l.Color --description $l.Desc --force --repo $Repo | Out-Null
            Write-Host "  OK    label '$($l.Name)'" -ForegroundColor Green
        } catch {
            Write-Host "  WARN  label '$($l.Name)': $_" -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
Write-Host "Instalados: $installed  Omitidos: $skipped" -ForegroundColor Cyan
if ($skipped -gt 0) { Write-Host "Los omitidos conservan la version del repo (personalizada)." -ForegroundColor DarkGray }
Write-Host "Commitea .github/ por el flujo normal (PR si el trabajo esta trackeado en el board)." -ForegroundColor Cyan
