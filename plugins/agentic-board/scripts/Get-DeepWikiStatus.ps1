<#  Get-DeepWikiStatus.ps1 — report DeepWiki indexing status for the current repo (#416).

    Resolves the repo from `origin`, checks GitHub visibility, probes DeepWiki,
    and returns one of four statuses:
      indexed     — DeepWiki has a generated wiki for this repo.
      not-indexed — The repo is public but DeepWiki has not indexed it yet.
      private     — The repo is private; DeepWiki only covers public repos.
      unknown     — Could not determine (network error, timeout, etc.).

    PUBLIC REPOS ONLY. Private repos require a paid Devin subscription — the command
    reports this clearly and never appears broken for private repos.

    Pure helpers are declared first and dot-source guarded so tests can import them
    without triggering the live path.

    Parameters:
      -Root              Repo root (default: cwd). Used for Get-RepoFromOrigin.
      -Repo              owner/name override — skips Get-RepoFromOrigin.
      -Json              Emit JSON instead of text output.
      -OverrideIsPrivate Inject privacy flag (bool) — bypasses the gh api call (for tests).
      -OverrideHttpStatus Inject HTTP status code (int) — bypasses Invoke-WebRequest (for tests).
      -OverrideHttpBody  Inject HTTP response body (string) — bypasses Invoke-WebRequest (for tests).
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [string]$Repo,
    [switch]$Json,
    [object]$OverrideIsPrivate,   # $true / $false — skip gh api privacy check
    [int]$OverrideHttpStatus,     # non-zero overrides Invoke-WebRequest status code
    [string]$OverrideHttpBody     # non-null overrides Invoke-WebRequest body
)
$ErrorActionPreference = 'Stop'

# ── Pure helpers (no side-effects, unit-testable) ────────────────────────────

# Build the DeepWiki URL for a given owner/name.
function Get-DeepWikiUrl {
    param([Parameter(Mandatory)][string]$Repo)
    "https://deepwiki.com/$Repo"
}

# Classify DeepWiki indexing status from a probed HTTP response.
# Returns 'indexed' | 'not-indexed' | 'unknown'.
# DeepWiki returns HTTP 200 for both indexed and not-indexed public repos.
# A not-indexed repo shows an invitation to index; an indexed repo shows the wiki.
# We look for definitive "not indexed" text markers.
function Resolve-DeepWikiIndex {
    param([int]$HttpStatus, [string]$HttpBody)
    if ($HttpStatus -eq 0)   { return 'unknown' }
    if ($HttpStatus -ne 200) { return 'unknown' }
    # DeepWiki landing-page phrases for unindexed repos.
    # Requires "repo(sitory)" context for start/index patterns so a wiki page discussing
    # indexing concepts ("the B-tree index is used for fast lookups") is never flagged.
    if ([string]$HttpBody -match '(?i)(start.{0,15}index.{0,25}repo(sitory)?|index.{0,15}this.{0,15}repo(sitory)?|not.{0,15}indexed|generate.{0,20}wiki|add.{0,20}to.{0,20}wiki)') {
        return 'not-indexed'
    }
    return 'indexed'
}

# ── Dot-source guard (tests import only the pure helpers above) ─────────────
if ($MyInvocation.InvocationName -eq '.' -or $env:ABIOS_DOTSOURCE_GUARD -eq '1') { return }

# ── Resolve repo ─────────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
if (-not $Repo) { $Repo = Get-RepoFromOrigin -Path $Root }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo must be owner/name (got '$Repo')." }
$deepWikiUrl = Get-DeepWikiUrl -Repo $Repo

# ── Privacy check ────────────────────────────────────────────────────────────
$isPrivate = $false
if ($null -ne $OverrideIsPrivate) {
    $isPrivate = [bool]$OverrideIsPrivate
} else {
    try {
        $raw = Invoke-Gh -GhArgs @('api', "repos/$Repo", '--jq', '.private') -What "check privacy for $Repo"
        $isPrivate = ($raw -join '').Trim() -eq 'true'
    } catch {
        # Best-effort: if gh fails, assume public (DeepWiki probe will clarify)
        $isPrivate = $false
    }
}

# ── Early-exit for private repos ─────────────────────────────────────────────
if ($isPrivate) {
    $result = [pscustomobject]@{
        repo      = $Repo
        url       = $deepWikiUrl
        isPrivate = $true
        status    = 'private'
        message   = 'Private repos require a paid Devin subscription — DeepWiki only indexes public repositories.'
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4 } else {
        Write-Output "DeepWiki status for $Repo"
        Write-Output "  status  : private"
        Write-Output "  url     : $deepWikiUrl"
        Write-Output "  note    : Private repos require paid Devin. DeepWiki covers public repos only."
    }
    return
}

# ── HTTP probe for public repos ───────────────────────────────────────────────
$httpStatus = 0
$httpBody   = ''

if ($PSBoundParameters.ContainsKey('OverrideHttpStatus')) {
    $httpStatus = $OverrideHttpStatus
    $httpBody   = if ($PSBoundParameters.ContainsKey('OverrideHttpBody')) { $OverrideHttpBody } else { '' }
} else {
    try {
        $resp = Invoke-WebRequest -Uri $deepWikiUrl -TimeoutSec 10 -ErrorAction SilentlyContinue
        $httpStatus = [int]$resp.StatusCode
        $httpBody   = [string]$resp.Content
    } catch {
        $httpStatus = 0
        $httpBody   = ''
    }
}

$indexStatus = Resolve-DeepWikiIndex -HttpStatus $httpStatus -HttpBody $httpBody

$messageMap = @{
    'indexed'     = "DeepWiki has indexed this repository. Open the URL to read the generated wiki."
    'not-indexed' = "Not yet indexed. Open the URL and click 'Index this repository' to generate the wiki."
    'unknown'     = "Could not determine indexing status (network error or timeout). Open the URL to check manually."
}

$result = [pscustomobject]@{
    repo      = $Repo
    url       = $deepWikiUrl
    isPrivate = $false
    status    = $indexStatus
    message   = $messageMap[$indexStatus]
}

if ($Json) { $result | ConvertTo-Json -Depth 4 } else {
    Write-Output "DeepWiki status for $Repo"
    Write-Output ("  status  : {0}" -f $indexStatus)
    Write-Output ("  url     : {0}" -f $deepWikiUrl)
    Write-Output ("  note    : {0}" -f $messageMap[$indexStatus])
    Write-Output ""
    Write-Output "PUBLIC REPOS ONLY — private repos require paid Devin (https://cognition.ai)."
}
