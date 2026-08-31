<#
.SYNOPSIS
    Extract one version's notes from a Keep-a-Changelog CHANGELOG (release L1, #322).

.DESCRIPTION
    The release workflow (.github/workflows/release.yml) turns a version bump on main into a
    git tag + a GitHub Release. The release body is that version's block from CHANGELOG.md — the
    same text a human reads under `## [X.Y.Z] - DATE`, minus the header line itself (the release
    title already carries the version).

    The parser is a pure function (Get-ChangelogSection) so it is unit-tested with no files and no
    gh. The script body reads CHANGELOG.md, extracts the requested version, and prints the notes to
    stdout for the workflow to capture with `--notes-file`. A version with no section is NOT fatal:
    the tag is the point (provenance / rollback), so it emits a GitHub Actions ::warning:: and falls
    back to a pointer body rather than blocking the release.

.PARAMETER Version
    X.Y.Z to extract. Default: the version in plugins/agentic-board/.claude-plugin/plugin.json.

.PARAMETER ChangelogPath
    Path to the changelog. Default: CHANGELOG.md in the cwd.

.EXAMPLE
    ./scripts/Get-ReleaseNotes.ps1 -Version 0.21.0
    ./scripts/Get-ReleaseNotes.ps1 -Version 0.21.0 -ChangelogPath CHANGELOG.md > notes.md
#>
[CmdletBinding()]
param(
    [string]$Version       = '',
    [string]$ChangelogPath = 'CHANGELOG.md'
)

# ------------------------------------------------------------------ pure helper
# Return the notes for exactly $Version: the text between that version's header
# (## [X.Y.Z] ...) and the next `## [` header (any version, including
# [Unreleased]) or end-of-file, trimmed, with the header line itself dropped.
# Returns $null when the version has no section. Pure -> unit-testable.
function Get-ChangelogSection {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Version
    )
    # Match `## [<version>]` with any trailing text on the line (e.g. ` - 2026-07-17`), then
    # capture everything up to the next `## [` header or the end of the document. The version is
    # regex-escaped so its dots are literal and 0.2.0 can never match 0.21.0.
    $rx = '(?ms)^\#\#[ \t]+\[' + [regex]::Escape($Version) + '\][^\r\n]*\r?\n(.*?)(?=^\#\#[ \t]+\[|\z)'
    $m  = [regex]::Match($Text, $rx)
    if (-not $m.Success) { return $null }
    $body = $m.Groups[1].Value.Trim()
    if (-not $body) { return $null }
    return $body
}

# Dot-source guard: with $env:ABIOS_RELEASENOTES_DOTSOURCE set, return after defining the pure
# helper WITHOUT touching disk — lets the tests exercise Get-ChangelogSection directly.
if ($env:ABIOS_RELEASENOTES_DOTSOURCE) { return }

$ErrorActionPreference = 'Stop'

if (-not $Version) {
    # Single source of truth for the version (same file the workflow reads). Explicit path, not a
    # recursive search: that search picks up a stale gitignored worktree copy of plugin.json (#319).
    $pluginJson = Join-Path $PSScriptRoot '..' 'plugins' 'agentic-board' '.claude-plugin' 'plugin.json'
    if (-not (Test-Path $pluginJson)) { throw "No encuentro plugin.json en $pluginJson (pasa -Version)." }
    $Version = ([System.IO.File]::ReadAllText((Resolve-Path $pluginJson)) | ConvertFrom-Json).version
    if (-not $Version) { throw "plugin.json no tiene 'version' (pasa -Version)." }
}

if (-not (Test-Path $ChangelogPath)) { throw "No existe $ChangelogPath." }
$text  = [System.IO.File]::ReadAllText((Resolve-Path $ChangelogPath))
$notes = Get-ChangelogSection -Text $text -Version $Version

if (-not $notes) {
    # Not fatal: the tag/release is worth creating for provenance even without notes. Surface the
    # gap as an Actions warning and fall back to a pointer body.
    Write-Warning "CHANGELOG.md has no section for [$Version] — releasing with a pointer body."
    Write-Host "::warning::No CHANGELOG.md section for [$Version]; release notes fall back to a pointer."
    $notes = "See [CHANGELOG.md](CHANGELOG.md) for the changes in this release."
}

# stdout = the notes, for `gh release create --notes-file`.
Write-Output $notes
