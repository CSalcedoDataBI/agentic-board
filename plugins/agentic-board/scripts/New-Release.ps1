<#
.SYNOPSIS
    Prepare a release: bump the version, fold the CHANGELOG, keep the manifests
    consistent. Prepares files only — never commits, tags, or pushes.

.DESCRIPTION
    A release today is three manual edits kept in sync by hand: bump `version` in
    plugin.json, move the CHANGELOG `[Unreleased]` block under a dated version
    header, and make sure marketplace.json still matches plugin.json. This script
    wires those together behind one command (#206, part of #200):

      1. Reads the current version from the SINGLE source of truth (plugin.json).
      2. Computes the next version (-Bump major|minor|patch, or explicit -Version).
      3. Writes it back into plugin.json (targeted regex — the rest of the file,
         including its em dash, is byte-preserved).
      4. Folds the board's Done issues into the CHANGELOG under the new version by
         delegating to Board-Changelog.ps1 -Write (skip with -NoChangelog; a gh
         failure degrades to a warning so an offline bump still succeeds).
      5. Validates that marketplace.json's plugin entry still matches plugin.json
         (name + description) — the "no duplicate metadata drift" guard. With
         -SyncManifest it rewrites the marketplace description from plugin.json
         instead of only reporting the drift.

    It then prints `git diff --stat` of what changed and STOPS. Committing,
    tagging, and pushing stay the maintainer's call (review the diff first).

    plugin.json is the source of truth: version lives ONLY there, and the plugin
    entry in marketplace.json mirrors its name + description.

.PARAMETER Bump
    Which semver part to increment: major | minor | patch (default patch).
    Ignored when -Version is given.

.PARAMETER Version
    Explicit X.Y.Z to release. Overrides -Bump.

.PARAMETER Check
    Read-only: validate that plugin.json and marketplace.json are consistent and
    that the current version is valid semver. Changes nothing. Exit 1 on drift.
    (Reusable by the docs-freshness gate, #203.)

.PARAMETER SyncManifest
    When the marketplace plugin entry has drifted from plugin.json, rewrite its
    description from plugin.json (exact-string replace, formatting preserved)
    instead of only reporting the drift.

.PARAMETER NoChangelog
    Skip the CHANGELOG fold (only bump the version + sync the manifest).

.PARAMETER ProjectNum
    Board number passed to Board-Changelog.ps1 (default 13).

.PARAMETER TokenVar
    Windows USER env var holding the PAT, passed to Board-Changelog (default
    GITHUB_TOKEN_PERSONAL).

.PARAMETER DryRun
    Print the current -> next version and the planned steps without writing.

.EXAMPLE
    .\New-Release.ps1 -Check
    .\New-Release.ps1 -Bump minor -DryRun
    .\New-Release.ps1 -Bump patch
    .\New-Release.ps1 -Version 1.0.0 -SyncManifest
#>
[CmdletBinding()]
param(
    [ValidateSet('major','minor','patch')][string]$Bump = 'patch',
    [string]$Version = '',
    [switch]$Check,
    [switch]$SyncManifest,
    [switch]$NoChangelog,
    [int]   $ProjectNum = 13,
    [string]$TokenVar   = 'GITHUB_TOKEN_PERSONAL',
    [switch]$DryRun
)

# ------------------------------------------------------------------ pure helpers
# Strict X.Y.Z semver: no leading zeros in a numeric identifier, no pre-release/build
# suffix (we only ship plain releases). Shared by the bump + the explicit -Version check.
$script:SemVerRx = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'

# Bump one part of an X.Y.Z semver. Pure -> unit-testable.
function Get-NextVersion {
    param(
        [Parameter(Mandatory)][string]$Current,
        [ValidateSet('major','minor','patch')][string]$Bump = 'patch'
    )
    if ($Current -notmatch $script:SemVerRx) {
        throw "Version '$Current' is not strict X.Y.Z semver."
    }
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]; $pat = [int]$Matches[3]
    switch ($Bump) {
        'major' { $maj++; $min = 0; $pat = 0 }
        'minor' { $min++; $pat = 0 }
        'patch' { $pat++ }
    }
    "$maj.$min.$pat"
}

# Read the version out of a plugin.json's raw text (same regex Board-Changelog uses).
function Get-PluginVersion {
    param([Parameter(Mandatory)][string]$Raw)
    $m = [regex]::Match($Raw, '"version"\s*:\s*"([^"]+)"')
    if (-not $m.Success) { throw "No version field found in plugin.json text." }
    $m.Groups[1].Value
}

# Return the raw text with the version field set to $NewVersion (only the value
# changes; everything else is byte-preserved). Requires EXACTLY ONE "version" field
# so a future nested `version` can never be edited by mistake. Pure -> testable.
function Set-VersionInText {
    param([Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)][string]$NewVersion)
    $rx = [regex]'("version"\s*:\s*")[^"]+(")'
    $n  = $rx.Matches($Raw).Count
    if ($n -eq 0) { throw "No version field to bump." }
    if ($n -gt 1) { throw "Found $n 'version' fields in plugin.json — ambiguous, refusing to guess." }
    $rx.Replace($Raw, "`${1}$NewVersion`${2}", 1)
}

# Return the raw text with the FIRST occurrence of $Old replaced by $New (exact
# string, so JSON formatting/encoding is preserved). Refuses a replacement value
# that would need JSON escaping (quote, backslash, or control char) rather than
# emit invalid JSON. Pure -> testable.
function Set-DescriptionInText {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )
    if ($New -match '["\\\x00-\x1f]') {
        throw "Replacement description contains a character that needs JSON escaping — sync it manually."
    }
    $idx = $Raw.IndexOf($Old, [System.StringComparison]::Ordinal)
    if ($idx -lt 0) { throw "Could not find the current description to replace." }
    $Raw.Substring(0, $idx) + $New + $Raw.Substring($idx + $Old.Length)
}

# Compare a parsed plugin.json against a parsed marketplace.json. The marketplace
# entry whose name matches plugin.name must exist and carry the same description
# (plugin.json is the source of truth). Pure -> testable with plain objects.
# Scope note: the marketplace-LEVEL `name`/`description` (the store's own pitch)
# are intentionally NOT checked — they describe the marketplace, not this plugin,
# so they are allowed to differ. Only the plugin ENTRY is the identity duplicate.
function Test-ManifestConsistency {
    param([Parameter(Mandatory)]$Plugin, [Parameter(Mandatory)]$Marketplace)
    $issues = @()
    $entry = $Marketplace.plugins | Where-Object { $_.name -eq $Plugin.name } | Select-Object -First 1
    if (-not $entry) {
        $issues += "marketplace.json has no plugins[] entry named '$($Plugin.name)' (the plugin.json name)."
    } else {
        if ($entry.description -ne $Plugin.description) {
            $issues += "marketplace plugin entry '$($Plugin.name)' description has drifted from plugin.json."
        }
    }
    [pscustomobject]@{ Consistent = ($issues.Count -eq 0); Issues = $issues }
}

# Dot-source guard: with $env:ABIOS_RELEASE_DOTSOURCE set, return after defining
# the pure helpers WITHOUT touching disk/git — lets the tests unit-test them.
if ($env:ABIOS_RELEASE_DOTSOURCE) { return }

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------- disk (side-effecting)
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path }
$pluginJson = (Resolve-Path (Join-Path $PSScriptRoot '..' '.claude-plugin' 'plugin.json')).Path
$marketJson = (Resolve-Path (Join-Path $repoRoot '.claude-plugin' 'marketplace.json')).Path
$changelog  = Join-Path $repoRoot 'CHANGELOG.md'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Read JSON as UTF-8 explicitly: Windows PowerShell's Get-Content -Raw decodes with
# the ANSI code page, which would mangle the em dash in the descriptions before we
# ever write it back. [IO.File]::ReadAllText is UTF-8 on every PowerShell version.
$pluginRaw = [System.IO.File]::ReadAllText($pluginJson)
$plugin    = $pluginRaw | ConvertFrom-Json
$marketRaw = [System.IO.File]::ReadAllText($marketJson)
$market    = $marketRaw | ConvertFrom-Json
$current   = Get-PluginVersion -Raw $pluginRaw

$consistency = Test-ManifestConsistency -Plugin $plugin -Marketplace $market

# --- -Check: validate only, change nothing ------------------------------------
if ($Check) {
    Write-Host "=== Release check  ($([System.IO.Path]::GetFileName($repoRoot))) ===" -ForegroundColor Cyan
    Write-Host "  Version (plugin.json): $current"
    try { Get-NextVersion -Current $current -Bump patch | Out-Null; Write-Host "  OK  version is valid semver" -ForegroundColor Green }
    catch { Write-Host "  FAIL  $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    if ($consistency.Consistent) {
        Write-Host "  OK  marketplace.json matches plugin.json (name + description)" -ForegroundColor Green
        exit 0
    }
    Write-Host "  FAIL  manifest drift:" -ForegroundColor Red
    $consistency.Issues | ForEach-Object { Write-Host "        - $_" -ForegroundColor Red }
    Write-Host "        Fix marketplace.json, or re-run with -SyncManifest." -ForegroundColor DarkGray
    exit 1
}

$next = if ($Version) { $Version } else { Get-NextVersion -Current $current -Bump $Bump }
# Validate an explicit -Version too.
Get-NextVersion -Current $next -Bump patch | Out-Null

Write-Host "=== Prepare release  $current -> $next ===" -ForegroundColor Cyan
Write-Host "  plugin.json : $pluginJson"
Write-Host "  marketplace : $marketJson"
Write-Host "  changelog   : $changelog"
# A release must not ship drifted metadata. Resolve it up front: -SyncManifest fixes
# it (and we re-check from disk), otherwise the release is blocked — no half-writes.
$willSync = $SyncManifest -and -not $consistency.Consistent
if (-not $consistency.Consistent) {
    Write-Host "  Manifest drift detected:" -ForegroundColor Yellow
    $consistency.Issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
    if (-not $SyncManifest) {
        Write-Host "    Fix marketplace.json, or re-run with -SyncManifest." -ForegroundColor DarkGray
        if (-not $DryRun) { throw "Manifest drift — refusing to prepare a release with mismatched manifests." }
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY-RUN — nothing written. Planned:" -ForegroundColor DarkGray
    if ($willSync) { Write-Host "  1. sync marketplace description from plugin.json" }
    Write-Host "  2. set plugin.json version -> $next"
    if (-not $NoChangelog) { Write-Host "  3. fold Done issues into CHANGELOG under [$next] (/board changelog -Write)" }
    Write-Host "  then: review 'git diff' and commit 'chore(release): $next' yourself."
    exit 0
}

# 1. sync the marketplace from plugin.json FIRST — a sync that can't succeed throws
#    here, before we touch plugin.json, so a release never lands half-done.
if ($willSync) {
    $entry = $market.plugins | Where-Object { $_.name -eq $plugin.name } | Select-Object -First 1
    if (-not $entry) {
        throw "Cannot sync: marketplace.json has no plugins[] entry named '$($plugin.name)'. Fix it manually."
    }
    $mpNew = Set-DescriptionInText -Raw $marketRaw -Old $entry.description -New $plugin.description
    [System.IO.File]::WriteAllText($marketJson, $mpNew, $Utf8NoBom)
    # Re-check from disk: if anything is still off, fail loudly rather than exit 0.
    $recheck = Test-ManifestConsistency -Plugin $plugin -Marketplace ([System.IO.File]::ReadAllText($marketJson) | ConvertFrom-Json)
    if (-not $recheck.Consistent) {
        throw "marketplace.json still inconsistent after sync: $($recheck.Issues -join '; ')"
    }
    Write-Host "  OK  marketplace description synced from plugin.json" -ForegroundColor Green
}

# 2. bump plugin.json
[System.IO.File]::WriteAllText($pluginJson, (Set-VersionInText -Raw $pluginRaw -NewVersion $next), $Utf8NoBom)
Write-Host "  OK  plugin.json version -> $next" -ForegroundColor Green

# 3. fold the CHANGELOG (delegates to the existing board-driven generator)
if (-not $NoChangelog) {
    try {
        & (Join-Path $PSScriptRoot 'Board-Changelog.ps1') -ProjectNum $ProjectNum -Version $next -Write -ChangelogPath $changelog -TokenVar $TokenVar
    } catch {
        Write-Host "  WARN  CHANGELOG fold skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "        (bump still applied; run /board changelog -Write manually once online)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Changed files (review before committing):" -ForegroundColor Cyan
git -C $repoRoot diff --stat
Write-Host ""
Write-Host "Next (your call): review the diff, then commit 'chore(release): $next' — no tag/push done." -ForegroundColor DarkGray
