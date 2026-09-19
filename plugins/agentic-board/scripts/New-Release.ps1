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

    It also checks the CHOICE of bump against what is under `## [Unreleased]` (#676). The number
    is supposed to say what kind of change the release contains, and the tooling used to agree
    with anything: 0.39.0 was proposed for a batch containing only `### Fixed` entries ("big batch,
    bigger number") and nothing objected. The minimum is mechanical:

        only `### Fixed` / `### Security`                  -> patch
        any `### Added` / `Changed` / `Deprecated` / `Removed`
        (or a header this check does not know)             -> minor
        a `BREAKING` marker in an entry                    -> major (minor while the version is 0.x,
                                                              where a breaking change is by
                                                              convention a minor bump)

    A SMALLER bump than that minimum is refused (nothing is written); a LARGER one is a legitimate
    maintainer call and only warns. The rule reads the headers and markers the maintainer wrote -
    it does not take over the curation of the block.

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
    (Reusable by the docs-freshness gate, #203.) Also reports the minimum bump implied by
    `[Unreleased]`; when -Bump or -Version is given as well, that planned bump is checked against
    it (smaller -> exit 1, larger -> warning).

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

# ── Bump vs. what is actually in [Unreleased] (#676) ───────────────────────────
$script:BumpRank = @{ patch = 1; minor = 2; major = 3 }

# The body of the `## [Unreleased]` section, or $null when there is none. Pure.
function Get-UnreleasedBlock {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?ms)^##[ \t]*\[Unreleased\][ \t]*\r?\n(.*?)(?=^##[ \t]*\[|\z)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

# The minimum bump the `[Unreleased]` block implies, from the `###` headers that actually contain
# entries and from an explicit BREAKING marker. Pure.
#
# Returns @{ minimum = 'patch'|'minor'|'major'|$null; reasons; sections; breaking }.
# $null = nothing under [Unreleased] to release. Only headers WITH entries count: an empty
# `### Added` left over from a template must not raise the bar.
function Get-MinimumBump {
    param([string]$Block, [string]$Current = '')
    $reasons = New-Object System.Collections.Generic.List[string]
    $sections = @()
    $rank = 0
    if (-not $Block -or -not $Block.Trim()) { return @{ minimum = $null; reasons = @(); sections = @(); breaking = $false } }

    $counts = [ordered]@{}
    $cur = ''
    foreach ($line in ($Block -split "`r?`n")) {
        $h = [regex]::Match($line, '^###[ \t]+(.+?)[ \t]*$')
        if ($h.Success) { $cur = $h.Groups[1].Value; if (-not $counts.Contains($cur)) { $counts[$cur] = 0 }; continue }
        if ($cur -and $line.Trim()) { $counts[$cur] = 1 + [int]$counts[$cur] }
    }
    foreach ($name in $counts.Keys) {
        if ($counts[$name] -le 0) { continue }
        $sections += $name
        switch -Regex ($name) {
            '^(?i)(fixed|security)$'                     { $r = 1; $why = "### $name has entries -> at least patch" }
            '^(?i)(added|changed|deprecated|removed)$'   { $r = 2; $why = "### $name has entries -> at least minor" }
            default                                       { $r = 2; $why = "### $name is not a header this check can prove is only a fix -> at least minor" }
        }
        if ($r -gt $rank) { $rank = $r }
        $reasons.Add($why)
    }
    # An explicit marker in the entries, not an inference from wording.
    $breaking = [bool]([regex]::IsMatch($Block, '\bBREAKING\b'))
    if ($breaking) {
        $zeroX = ($Current -match '^0\.')
        if ($zeroX) { if (2 -gt $rank) { $rank = 2 }; $reasons.Add('a BREAKING entry -> at least minor (version is 0.x: a breaking change is a minor bump by convention)') }
        else        { $rank = 3; $reasons.Add('a BREAKING entry -> major') }
    }
    if ($rank -eq 0) { return @{ minimum = $null; reasons = @(); sections = @($sections); breaking = $breaking } }
    $min = @('', 'patch', 'minor', 'major')[$rank]
    return @{ minimum = $min; reasons = @($reasons); sections = @($sections); breaking = $breaking }
}

# What kind of bump is Current -> Next? 'major' | 'minor' | 'patch'; throws when Next does not move
# forward, because a "release" that is not newer than the current version is not a release. Pure.
function Get-BumpKind {
    param([Parameter(Mandatory)][string]$Current, [Parameter(Mandatory)][string]$Next)
    if ($Current -notmatch $script:SemVerRx) { throw "Version '$Current' is not strict X.Y.Z semver." }
    $c = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    if ($Next -notmatch $script:SemVerRx) { throw "Version '$Next' is not strict X.Y.Z semver." }
    $n = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    if ($n[0] -gt $c[0]) { return 'major' }
    if ($n[0] -eq $c[0] -and $n[1] -gt $c[1]) { return 'minor' }
    if ($n[0] -eq $c[0] -and $n[1] -eq $c[1] -and $n[2] -gt $c[2]) { return 'patch' }
    throw "Version $Next is not newer than the current $Current."
}

# Judge a chosen bump against the minimum. Pure. Returns @{ ok; warn; message }:
# smaller -> ok=$false; larger -> ok=$true, warn=$true (a maintainer call, e.g. marketing a milestone);
# equal, or nothing to compare against -> ok, no warn.
function Test-BumpChoice {
    param([Parameter(Mandatory)][string]$Chosen, $Minimum)
    if (-not $Minimum.minimum) {
        return @{ ok = $true; warn = $false; message = 'nothing under [Unreleased] implies a minimum bump' }
    }
    $why = ($Minimum.reasons -join '; ')
    $cr = $script:BumpRank[$Chosen]; $mr = $script:BumpRank[$Minimum.minimum]
    if ($cr -lt $mr) {
        return @{ ok = $false; warn = $false
                  message = "a '$Chosen' bump is smaller than what [Unreleased] contains: minimum is '$($Minimum.minimum)' ($why)" }
    }
    if ($cr -gt $mr) {
        return @{ ok = $true; warn = $true
                  message = "'$Chosen' is larger than the minimum '$($Minimum.minimum)' ($why) - allowed, but the number should say what changed" }
    }
    return @{ ok = $true; warn = $false; message = "'$Chosen' matches the minimum implied by [Unreleased] ($why)" }
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

# What is under [Unreleased] decides the MINIMUM bump (#676). Read before anything is written.
$clRaw   = if (Test-Path -LiteralPath $changelog) { [System.IO.File]::ReadAllText($changelog) } else { '' }
$minBump = Get-MinimumBump -Block (Get-UnreleasedBlock -Text $clRaw) -Current $current
# Was a bump actually chosen, or is -Bump just its default? Only a real choice can be judged.
$bumpChosen = $PSBoundParameters.ContainsKey('Bump') -or [bool]$Version

# --- -Check: validate only, change nothing ------------------------------------
if ($Check) {
    Write-Host "=== Release check  ($([System.IO.Path]::GetFileName($repoRoot))) ===" -ForegroundColor Cyan
    Write-Host "  Version (plugin.json): $current"
    try { Get-NextVersion -Current $current -Bump patch | Out-Null; Write-Host "  OK  version is valid semver" -ForegroundColor Green }
    catch { Write-Host "  FAIL  $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    $checkFailed = $false
    if ($consistency.Consistent) {
        Write-Host "  OK  marketplace.json matches plugin.json (name + description)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  manifest drift:" -ForegroundColor Red
        $consistency.Issues | ForEach-Object { Write-Host "        - $_" -ForegroundColor Red }
        Write-Host "        Fix marketplace.json, or re-run with -SyncManifest." -ForegroundColor DarkGray
        $checkFailed = $true
    }
    # The bump rule (#676): report the minimum; judge a planned bump when one was given.
    if (-not $minBump.minimum) {
        Write-Host "  --  nothing under [Unreleased]: no minimum bump to enforce" -ForegroundColor DarkGray
    } elseif (-not $bumpChosen) {
        Write-Host "  --  [Unreleased] implies at least a '$($minBump.minimum)' bump ($($minBump.reasons -join '; '))" -ForegroundColor DarkGray
    } else {
        $plannedNext = if ($Version) { $Version } else { Get-NextVersion -Current $current -Bump $Bump }
        try { $plannedKind = Get-BumpKind -Current $current -Next $plannedNext }
        catch { Write-Host "  FAIL  $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
        $judge = Test-BumpChoice -Chosen $plannedKind -Minimum $minBump
        if (-not $judge.ok)   { Write-Host "  FAIL  $($judge.message)" -ForegroundColor Red; $checkFailed = $true }
        elseif ($judge.warn)  { Write-Host "  WARN  $($judge.message)" -ForegroundColor Yellow }
        else                  { Write-Host "  OK  $($judge.message)" -ForegroundColor Green }
    }
    if ($checkFailed) { exit 1 }
    exit 0
}

$next = if ($Version) { $Version } else { Get-NextVersion -Current $current -Bump $Bump }
# Validate an explicit -Version too.
Get-NextVersion -Current $next -Bump patch | Out-Null

# The choice of bump against what [Unreleased] contains (#676). A smaller bump is refused before
# anything is written - including under -DryRun, which must show the refusal, not hide it.
$nextKind = Get-BumpKind -Current $current -Next $next
$judge = Test-BumpChoice -Chosen $nextKind -Minimum $minBump
if (-not $judge.ok) {
    Write-Host "REFUSED: $($judge.message)" -ForegroundColor Red
    Write-Host "  Pick a bump that matches the entries (-Bump $($minBump.minimum)), or change what [Unreleased] says." -ForegroundColor DarkGray
    exit 1
}

Write-Host "=== Prepare release  $current -> $next ===" -ForegroundColor Cyan
if ($judge.warn) { Write-Host "  WARN  $($judge.message)" -ForegroundColor Yellow }
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
