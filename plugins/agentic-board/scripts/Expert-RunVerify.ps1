<#
.SYNOPSIS
    Completion check for /board expert runs — prove the run used the tool instead of asserting it.

.DESCRIPTION
    Nothing previously verified that a run recorded its evidence rather than just reporting that it
    did. This module closes that gap (#532, part of #526).

    A run is COMPLETE when three artifacts all exist and carry the [abios-evidence] marker:
      1. evidence/<issue>.md  — the versioned evidence file
      2. PR body              — the [abios-evidence] block in the pull request
      3. Issue comment        — an [abios-evidence] comment on the issue itself

    The check fails closed: unreadable or empty content is treated as MISSING, never as present.
    A run with no evidence is reported INCOMPLETE, and WHICH artifact is missing is named — a bare
    verdict without the name forces a second round of guessing.

    Pure check (no gh/network) behind a dot-source guard ($env:ABIOS_EXPERTRUNVERIFY_DOTSOURCE)
    so Pester can unit-test without the network. The CLI half fetches the three artifact contents
    via gh and passes them to the pure core.

.PARAMETER Issue
    The issue number whose evidence to check.

.PARAMETER PR
    The pull request number to inspect for an [abios-evidence] block.

.PARAMETER Repo
    owner/name. Resolved from git origin if omitted.

.EXAMPLE
    .\Expert-RunVerify.ps1 -Issue 532 -PR 557
    .\Expert-RunVerify.ps1 -Issue 532 -PR 557 -Repo CSalcedoDataBI/agentic-board
#>
[CmdletBinding()]
param(
    [int]$Issue = 0,
    [int]$PR    = 0,
    [string]$Repo     = "",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# Marker written by Format-EvidenceBlock and expected in every destination.
$script:EvidenceMarker = '[abios-evidence]'

<#
    Did a run actually write its evidence to all three required destinations?

    Takes the RAW content of each destination as a parameter — callers fetch it, so the check is
    testable without a network round-trip, and so the caller is forced to actually resolve the PR
    and issue rather than passing a number it never looked up.

    Fails closed: null, empty, or whitespace-only content is MISSING, never assumed present. A
    PR body of "Closes #532" has no marker, so it is missing. An empty comment list has no marker,
    so the comment is missing. "I could not read it" is not evidence.

    Returns @{ complete; missing; verdict }.
    `missing` lists EVERY absent artifact, not just the first — telling someone one reason at a
    time forces a round trip per artifact, and the same dishonesty this project keeps finding in
    its gates.
#>
function Test-RunArtifactsComplete {
    param(
        # Content of evidence/<issue>.md. Null or empty = file does not exist or could not be read.
        [AllowEmptyString()][AllowNull()][string]$EvidenceFileContent,
        # PR body content. Null or empty = PR body is blank or could not be read.
        [AllowEmptyString()][AllowNull()][string]$PrBodyContent,
        # All comment bodies on the issue. Empty = no comments were found.
        [string[]]$IssueCommentBodies = @()
    )
    $marker  = $script:EvidenceMarker
    $missing = @()

    # 1. Versioned evidence file — the durable record that outlives the PR.
    if ([string]::IsNullOrWhiteSpace($EvidenceFileContent) -or
        -not "$EvidenceFileContent".Contains($marker)) {
        $missing += 'evidence/<issue>.md (file missing or marker absent)'
    }

    # 2. PR body — the marker that surfaces on the PR page and is SHA-bound.
    if ([string]::IsNullOrWhiteSpace($PrBodyContent) -or
        -not "$PrBodyContent".Contains($marker)) {
        $missing += '[abios-evidence] block in PR body'
    }

    # 3. Issue comment — the durable marker that stays visible after the PR is closed.
    $hasComment = @($IssueCommentBodies | Where-Object { "$_".Contains($marker) }).Count -gt 0
    if (-not $hasComment) {
        $missing += '[abios-evidence] comment on the issue'
    }

    if ($missing.Count -eq 0) {
        return @{ complete = $true; missing = @(); verdict = 'COMPLETE' }
    }
    return @{
        complete = $false
        missing  = @($missing)
        verdict  = 'INCOMPLETE'
        reason   = "missing: $($missing -join '; ')"
    }
}

<#
    Render the completion verdict for a human or for a run's final report.
    Kept next to Test-RunArtifactsComplete so the verdict wording and the check cannot drift apart —
    a refusal nobody understands gets worked around instead of fixed.
#>
function Format-RunVerifyVerdict {
    param([Parameter(Mandatory)][hashtable]$Result)
    if ($Result.complete) {
        return "RUN VERIFY: COMPLETE — all three evidence artifacts carry the marker."
    }
    $lines = @("RUN VERIFY: INCOMPLETE — the run did not record its evidence. Missing:")
    foreach ($m in @($Result.missing)) { $lines += "  - $m" }
    $lines += "Record the evidence and re-run this check before considering the run done."
    return ($lines -join "`n")
}

# Dot-source guard: tests set $env:ABIOS_EXPERTRUNVERIFY_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTRUNVERIFY_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────

if ($Issue -le 0 -or $PR -le 0) {
    throw "Expert-RunVerify: -Issue <n> and -PR <n> are required."
}

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}

# Resolve repo from git origin if not provided.
if (-not $Repo) {
    . (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
    $Repo = Get-RepoFromOriginUrl (git remote get-url origin 2>$null)
}
if (-not $Repo) { throw "Expert-RunVerify: cannot resolve repo from git origin and -Repo was not given." }

# Fetch PR body (fail closed: empty on any error).
$prBody = ""
$prJson = gh pr view $PR --repo $Repo --json body 2>$null
if ($LASTEXITCODE -eq 0 -and $prJson) {
    try { $prBody = ($prJson | ConvertFrom-Json).body } catch { }
}

# Fetch issue comments (fail closed: empty array on any error).
$commentBodies = @()
$commentsJson  = gh issue view $Issue --repo $Repo --json comments 2>$null
if ($LASTEXITCODE -eq 0 -and $commentsJson) {
    try {
        $commentBodies = @(($commentsJson | ConvertFrom-Json).comments |
                          ForEach-Object { "$($_.body)" })
    } catch { }
}

# Read evidence file from the repo root (three levels above PSScriptRoot).
$repoRoot      = Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path | Select-Object -ExpandProperty Path
$evidencePath  = Join-Path $repoRoot 'evidence' "$Issue.md"
$evidenceContent = ""
if (Test-Path -LiteralPath $evidencePath) {
    try { $evidenceContent = Get-Content -Raw -LiteralPath $evidencePath } catch { }
}

$result = Test-RunArtifactsComplete `
    -EvidenceFileContent $evidenceContent `
    -PrBodyContent       $prBody `
    -IssueCommentBodies  $commentBodies

Write-Host ""
Write-Host (Format-RunVerifyVerdict -Result $result)
Write-Host ""

if (-not $result.complete) { exit 1 }
