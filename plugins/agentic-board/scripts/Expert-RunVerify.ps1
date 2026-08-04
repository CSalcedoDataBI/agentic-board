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
        [string[]]$IssueCommentBodies = @(),
        # The evidence file's repo-relative path, e.g. 'evidence/532.md' (#570). When given, the
        # PR body and the issue comment must not only carry the marker but REFERENCE this file
        # (the link stub) or carry a full '## Evidence' block (pre-#570 runs stay valid). A bare
        # marker with neither is a stamp, not evidence.
        [string]$EvidenceRef = ''
    )
    $marker  = $script:EvidenceMarker
    $missing = @()

    # The pre-#570 FULL block's signature is its results table header - NOT the '## Evidence'
    # heading, which the link stub also emits (review round 1: heading-as-fallback let a stub
    # with no link, or one pointing at another issue's file, pass for this one).
    $legacyBlock = '| Test | Command | Result | Detail |'

    # A surface satisfies its requirement with the marker AND substance: the stub that
    # references THIS issue's file, or a legacy full block. Marker alone is a stamp.
    $satisfies = {
        param($content)
        if ([string]::IsNullOrWhiteSpace($content)) { return $false }
        if (-not "$content".Contains($marker)) { return $false }
        if (-not "$EvidenceRef".Trim()) { return $true }
        return ("$content".Contains($EvidenceRef) -or "$content".Contains($legacyBlock))
    }

    # 1. Versioned evidence file — the durable record that outlives the PR, and since #570 the
    #    SINGLE source of truth the other two surfaces point at. In EvidenceRef mode it must
    #    carry SUBSTANCE beyond the marker (a table row or a section heading): pointers backed
    #    by a marker-only file would be evidence of nothing (review round 1).
    $fileOk = -not [string]::IsNullOrWhiteSpace($EvidenceFileContent) -and
              "$EvidenceFileContent".Contains($marker)
    if ($fileOk -and "$EvidenceRef".Trim()) {
        $fileOk = ("$EvidenceFileContent" -match '(?m)^\s*\|') -or ("$EvidenceFileContent" -match '(?m)^##\s')
    }
    if (-not $fileOk) {
        $missing += 'evidence/<issue>.md (file missing, marker absent, or no substantive content)'
    }

    # 2. PR body — the marker + link stub that surfaces on the PR page.
    if (-not (& $satisfies $PrBodyContent)) {
        $missing += '[abios-evidence] block or link stub in PR body'
    }

    # 3. Issue comment — the durable marker that stays visible after the PR is closed.
    $hasComment = @($IssueCommentBodies | Where-Object { & $satisfies $_ }).Count -gt 0
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

# Read the evidence file from the WORKING repo, never from a path relative to this script.
# $PSScriptRoot is <repo>/plugins/agentic-board/scripts only in this checkout; once installed the
# script lives in the plugin cache, where walking three levels up lands in the cache itself and the
# evidence file is never found — a check that always reports INCOMPLETE is as useless as one that
# always reports COMPLETE. The evidence belongs to the repo the run worked in: ask git for it.
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { $repoRoot = (Get-Location).Path }
$evidencePath  = Join-Path $repoRoot 'evidence' "$Issue.md"
$evidenceContent = ""
if (Test-Path -LiteralPath $evidencePath) {
    try { $evidenceContent = Get-Content -Raw -LiteralPath $evidencePath } catch { }
}

$result = Test-RunArtifactsComplete `
    -EvidenceFileContent $evidenceContent `
    -PrBodyContent       $prBody `
    -IssueCommentBodies  $commentBodies `
    -EvidenceRef         "evidence/$Issue.md"

Write-Host ""
Write-Host (Format-RunVerifyVerdict -Result $result)
Write-Host ""

if (-not $result.complete) { exit 1 }
