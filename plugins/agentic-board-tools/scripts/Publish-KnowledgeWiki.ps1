<#  Publish-KnowledgeWiki.ps1 — DEPRECATED alias for Publish-DocsWiki.ps1.

    The GitHub Wiki is a single git repository; having two publishers independently clone
    and push it causes race conditions and lost updates. Publish-DocsWiki.ps1 is now the
    single publisher: it generates ALL wiki pages (product docs + knowledge registry) in
    one clone → commit → push.

    This script is kept for backward compatibility with existing /knowledge wiki callers
    and any CI scripts that invoke it by name. All parameters are forwarded unchanged to
    Publish-DocsWiki.ps1. Use /docs wiki (Publish-DocsWiki.ps1) directly for new work. #>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Repo,
    [string]$TokenVar = '',
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$PagesOnly,
    [string]$OutDir,
    [switch]$DryRun,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

Write-Host "NOTE: /knowledge wiki delegates to /docs wiki." -ForegroundColor DarkYellow

$docsScript = Join-Path $PSScriptRoot 'Publish-DocsWiki.ps1'
$splat = @{ Root = $Root; Date = $Date }
if ($Repo)      { $splat['Repo']     = $Repo }
if ($TokenVar)  { $splat['TokenVar'] = $TokenVar }
if ($PagesOnly) { $splat['PagesOnly']= $PagesOnly }
if ($OutDir)    { $splat['OutDir']   = $OutDir }
if ($DryRun)    { $splat['DryRun']   = $DryRun }
if ($Json)      { $splat['Json']     = $Json }

& $docsScript @splat
