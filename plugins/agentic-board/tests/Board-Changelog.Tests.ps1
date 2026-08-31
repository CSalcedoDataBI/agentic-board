#Requires -Modules Pester
<#  Tests for Board-Changelog.ps1's CHANGELOG-write logic (#324).

    Board-Changelog.ps1 is side-effecting (reads the board over gh), so it exposes a dot-source
    guard: with $env:ABIOS_CHANGELOG_DOTSOURCE set it returns after defining the pure helpers
    without touching gh. These tests exercise Update-ChangelogText / Merge-UnreleasedBody directly.

    The bug (#324): the fold inserted the generated block ABOVE a hand-written `## [Unreleased]`,
    stranding the maintainer's curated entries under an orphan [Unreleased] below their own version.
    The fix renames [Unreleased] to the dated version header and merges the board entries into it. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Changelog.ps1' | Resolve-Path
    $env:ABIOS_CHANGELOG_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_CHANGELOG_DOTSOURCE = ''

    # Slice the text of the first version block (from its `## [` header to the next `## [` or EOF).
    function script:Get-FirstBlock([string]$Text) {
        $m = [regex]::Match($Text, '(?ms)^(##[ \t]*\[[^\]]+\].*?)(?=^##[ \t]*\[|\z)')
        if ($m.Success) { $m.Groups[1].Value } else { '' }
    }
    function script:New-Sections($added, $changed, $fixed) {
        [ordered]@{ Added = @($added); Changed = @($changed); Fixed = @($fixed) }
    }
}

Describe 'Update-ChangelogText — hand-written [Unreleased] present (#324)' {
    BeforeAll {
        $orig = @"
# Changelog

## [Unreleased]
### Added
- **Hand-written feature** (#294)
### Security
- **Hand-written hardening** (#295)

## [0.20.0] - 2026-07-10
### Added
- **Old shipped thing** (#100)
"@
        $sections = New-Sections @('- **Board feature** (#301)') @() @('- **Board fix** (#302)')
        $script:R = Update-ChangelogText -Original $orig -Block '' -Sections $sections -Version '0.21.0' -Date '2026-07-17'
        $script:First = Get-FirstBlock $R.Text
    }

    It 'reports Changed' { $R.Changed | Should -BeTrue }
    It 'renames [Unreleased] to the dated version header' { $R.Text | Should -Match '## \[0\.21\.0\] - 2026-07-17' }
    It 'leaves NO orphan [Unreleased] behind' { $R.Text | Should -Not -Match '\[Unreleased\]' }
    It 'keeps the previous version block' { $R.Text | Should -Match '## \[0\.20\.0\] - 2026-07-10' }

    It 'merges the board Added entry AFTER the hand-written one, in one ### Added' {
        $First | Should -Match '(?s)### Added.*Hand-written feature.*Board feature'
        ([regex]::Matches($First, '### Added')).Count | Should -Be 1
    }
    It 'creates a ### Fixed section for a board-only bucket' {
        $First | Should -Match '(?s)### Fixed.*Board fix'
    }
    It 'preserves a hand-written section the board has no opinion about' {
        $First | Should -Match '(?s)### Security.*Hand-written hardening'
    }
    It 'does not duplicate the already-cited hand-written issue' {
        ([regex]::Matches($R.Text, '#294')).Count | Should -Be 1
    }
}

Describe 'Update-ChangelogText — no [Unreleased], fully board-generated (unchanged behavior)' {
    BeforeAll {
        $orig = @"
# Changelog

## [0.20.0] - 2026-07-10
### Added
- **Old shipped thing** (#100)
"@
        $block = "## [0.21.0] - 2026-07-17`n### Added`n- **Board feature** (#301)"
        $sections = New-Sections @('- **Board feature** (#301)') @() @()
        $script:R = Update-ChangelogText -Original $orig -Block $block -Sections $sections -Version '0.21.0' -Date '2026-07-17'
    }

    It 'reports Changed' { $R.Changed | Should -BeTrue }
    It 'inserts the block under the # Changelog header, above the previous version' {
        $R.Text | Should -Match "(?s)# Changelog.*## \[0\.21\.0\].*## \[0\.20\.0\]"
    }
    It 'keeps the previous version intact' { $R.Text | Should -Match '## \[0\.20\.0\] - 2026-07-10' }
}

Describe 'Update-ChangelogText — [Unreleased] present but board contributed nothing' {
    It 'still renames the hand-written [Unreleased] to the version (release with only curated prose)' {
        $orig = @"
# Changelog

## [Unreleased]
### Changed
- **Only hand-written** (#294)

## [0.20.0] - 2026-07-10
### Added
- x (#100)
"@
        $r = Update-ChangelogText -Original $orig -Block '' -Sections (New-Sections @() @() @()) -Version '0.21.0' -Date '2026-07-17'
        $r.Changed | Should -BeTrue
        $r.Text | Should -Match '## \[0\.21\.0\] - 2026-07-17'
        $r.Text | Should -Not -Match '\[Unreleased\]'
        $r.Text | Should -Match '(?s)### Changed.*Only hand-written'
    }
}

Describe 'Update-ChangelogText — nothing to do' {
    It 'is a no-op when there is no [Unreleased] and no new board entries' {
        $orig = @"
# Changelog

## [0.20.0] - 2026-07-10
### Added
- x (#100)
"@
        $r = Update-ChangelogText -Original $orig -Block '## [0.21.0] - 2026-07-17' -Sections (New-Sections @() @() @()) -Version '0.21.0' -Date '2026-07-17'
        $r.Changed | Should -BeFalse
        $r.Text | Should -Be $orig
    }
}

Describe 'Select-PluginVersionFile — deterministic plugin.json, never a recursive guess (#319)' {
    It 'returns nothing when there are no candidates' {
        Select-PluginVersionFile -Candidates @() | Should -BeNullOrEmpty
    }
    It 'returns the single candidate' {
        Select-PluginVersionFile -Candidates @('C:\a\.claude-plugin\plugin.json') |
            Should -Be 'C:\a\.claude-plugin\plugin.json'
    }
    It 'dedups identical candidates down to one' {
        Select-PluginVersionFile -Candidates @('C:\a\plugin.json', 'C:\a\plugin.json') |
            Should -Be 'C:\a\plugin.json'
    }
    It 'THROWS on genuine ambiguity rather than guessing (the stale-worktree bug)' {
        { Select-PluginVersionFile -Candidates @('C:\a\plugin.json', 'C:\b\plugin.json') } |
            Should -Throw '*ambigua*'
    }
    It 'ignores blank/null entries' {
        Select-PluginVersionFile -Candidates @('', 'C:\a\plugin.json', $null) |
            Should -Be 'C:\a\plugin.json'
    }
}
