#Requires -Modules Pester
<#  Pester tests for scripts/Get-ReleaseNotes.ps1 (release L1, #322).

    Get-ReleaseNotes.ps1 reads CHANGELOG.md and prints one version's block for the release workflow
    to feed `gh release create --notes-file`. The extraction is a pure function (Get-ChangelogSection)
    behind a dot-source guard ($env:ABIOS_RELEASENOTES_DOTSOURCE), so these tests exercise it with no
    files and no gh. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'Get-ReleaseNotes.ps1' | Resolve-Path
    $env:ABIOS_RELEASENOTES_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_RELEASENOTES_DOTSOURCE = ''

    # A sample shaped exactly like this repo's CHANGELOG, including the stray empty [Unreleased]
    # block (#324) between two releases, and an older 0.2.0 to catch a 0.2.0-vs-0.21.0 mismatch.
    $script:Sample = @"
# Changelog

## [0.21.0] - 2026-07-17
### Added
- Thing A (#1)
### Fixed
- Thing B (#2)

## [0.20.0] - 2026-07-16
### Added
- Older thing (#3)

## [Unreleased]

## [0.2.0] - 2026-01-01
### Added
- Ancient thing (#4)
"@
}

Describe 'Get-ChangelogSection (release-notes extraction, #322)' {
    It 'returns the block body for a version, without the header line' {
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.21.0'
        $notes | Should -Match '### Added'
        $notes | Should -Match 'Thing A \(#1\)'
        $notes | Should -Match '### Fixed'
        $notes | Should -Match 'Thing B \(#2\)'
        $notes | Should -Not -Match '\[0\.21\.0\]'      # header line dropped (title carries it)
    }
    It 'stops at the next version header — no bleed into older releases' {
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.21.0'
        $notes | Should -Not -Match '0\.20\.0'
        $notes | Should -Not -Match 'Older thing'
        $notes | Should -Not -Match '(?m)^\#\# \['              # never contains another header
    }
    It 'stops before an [Unreleased] header too' {
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.20.0'
        $notes | Should -Match 'Older thing \(#3\)'
        $notes | Should -Not -Match 'Unreleased'
        $notes | Should -Not -Match 'Ancient'
    }
    It 'extracts the LAST block, running to end-of-file' {
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.2.0'
        $notes | Should -Match 'Ancient thing \(#4\)'
    }
    It 'does not confuse 0.2.0 with 0.21.0 (escaped dots + closing-bracket boundary)' {
        # 0.2.0 must resolve to the ancient block, NOT partially match inside [0.21.0].
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.2.0'
        $notes | Should -Match 'Ancient thing \(#4\)'
        $notes | Should -Not -Match 'Thing A'
    }
    It 'returns $null for a version that has no section' {
        Get-ChangelogSection -Text $script:Sample -Version '9.9.9' | Should -BeNullOrEmpty
    }
    It 'returns $null for a header with an empty body (e.g. [Unreleased])' {
        Get-ChangelogSection -Text $script:Sample -Version 'Unreleased' | Should -BeNullOrEmpty
    }
    It 'trims surrounding whitespace' {
        $notes = Get-ChangelogSection -Text $script:Sample -Version '0.21.0'
        $notes | Should -Not -Match '^\s'
        $notes | Should -Not -Match '\s$'
    }
    It 'handles CRLF line endings' {
        # Normalise to LF first, THEN to CRLF, so the sample is genuinely \r\n regardless of how
        # this test file was checked out. A naive -replace "`n","`r`n" would double-convert an
        # already-CRLF checkout (Windows CI) into \r\r\n — a malformed ending real files never have.
        $crlf = ($script:Sample -replace "`r`n", "`n") -replace "`n", "`r`n"
        $notes = Get-ChangelogSection -Text $crlf -Version '0.20.0'
        $notes | Should -Match 'Older thing \(#3\)'
        $notes | Should -Not -Match 'Unreleased'
    }
}
