#Requires -Modules Pester
<#  Pester tests for New-Release.ps1 — release prep (#206).

    New-Release.ps1 is side-effecting (disk + git + Board-Changelog), so it exposes
    a dot-source guard: with $env:ABIOS_RELEASE_DOTSOURCE set it returns after
    defining the pure helpers without touching disk/git. These tests exercise the
    pure version + manifest-consistency logic. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'New-Release.ps1' | Resolve-Path
    $env:ABIOS_RELEASE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_RELEASE_DOTSOURCE = ''
}

Describe 'Get-NextVersion' {
    It 'bumps patch by default' { Get-NextVersion -Current '0.17.0' | Should -Be '0.17.1' }
    It 'bumps minor and zeroes patch' { Get-NextVersion -Current '0.17.3' -Bump minor | Should -Be '0.18.0' }
    It 'bumps major and zeroes minor+patch' { Get-NextVersion -Current '0.17.3' -Bump major | Should -Be '1.0.0' }
    It 'rejects a non-semver version' { { Get-NextVersion -Current '0.17' } | Should -Throw }
    It 'rejects a version with a suffix' { { Get-NextVersion -Current '1.0.0-rc1' } | Should -Throw }
    It 'rejects leading zeros (strict semver)' { { Get-NextVersion -Current '01.02.03' } | Should -Throw }
}

Describe 'Get-PluginVersion' {
    It 'extracts the version from minified plugin.json text' {
        Get-PluginVersion -Raw '{"name":"x","version":"0.17.0","author":{}}' | Should -Be '0.17.0'
    }
    It 'tolerates whitespace around the colon' {
        Get-PluginVersion -Raw '{ "version" : "1.2.3" }' | Should -Be '1.2.3'
    }
    It 'throws when there is no version field' {
        { Get-PluginVersion -Raw '{"name":"x"}' } | Should -Throw
    }
}

Describe 'Set-VersionInText' {
    It 'changes only the version value and preserves the rest (incl. the em dash)' {
        $raw = '{"name":"agentic-board","version":"0.17.0","description":"a board — not a Kanban"}'
        $out = Set-VersionInText -Raw $raw -NewVersion '0.18.0'
        $out | Should -Be '{"name":"agentic-board","version":"0.18.0","description":"a board — not a Kanban"}'
    }
    It 'does not touch a version-like value elsewhere' {
        $raw = '{"version":"0.17.0","note":"needs version 9.9.9"}'
        $out = Set-VersionInText -Raw $raw -NewVersion '0.17.1'
        $out | Should -Match '"version":"0.17.1"'
        $out | Should -Match 'needs version 9.9.9'   # untouched
    }
    It 'throws when there is no version field' {
        { Set-VersionInText -Raw '{"name":"x"}' -NewVersion '1.0.0' } | Should -Throw
    }
    It 'throws when there is more than one version field (ambiguous)' {
        { Set-VersionInText -Raw '{"version":"1.0.0","dep":{"version":"2.0.0"}}' -NewVersion '1.0.1' } | Should -Throw
    }
}

Describe 'Set-DescriptionInText' {
    It 'replaces only the FIRST occurrence of the old string' {
        $raw = 'A: "old" | B: "old"'
        Set-DescriptionInText -Raw $raw -Old 'old' -New 'new' | Should -Be 'A: "new" | B: "old"'
    }
    It 'preserves everything around the match (formatting kept)' {
        $raw = '{ "description": "the OLD pitch" }'
        Set-DescriptionInText -Raw $raw -Old 'the OLD pitch' -New 'the new pitch — dashed' |
            Should -Be '{ "description": "the new pitch — dashed" }'
    }
    It 'throws when the old string is not present' {
        { Set-DescriptionInText -Raw '{}' -Old 'missing' -New 'x' } | Should -Throw
    }
    It 'refuses a replacement that would need JSON escaping (quote)' {
        { Set-DescriptionInText -Raw 'a old b' -Old 'old' -New 'has a " quote' } | Should -Throw
    }
    It 'refuses a replacement with a backslash' {
        { Set-DescriptionInText -Raw 'a old b' -Old 'old' -New 'a\b' } | Should -Throw
    }
    It 'refuses a replacement with a control character (newline)' {
        { Set-DescriptionInText -Raw 'a old b' -Old 'old' -New "line1`nline2" } | Should -Throw
    }
}

Describe 'Test-ManifestConsistency' {
    BeforeAll {
        function New-Plugin($name, $desc) { [pscustomobject]@{ name = $name; description = $desc } }
        function New-Market($entries) { [pscustomobject]@{ plugins = $entries } }
    }

    It 'is consistent when the plugin entry name + description match' {
        $p = New-Plugin 'agentic-board' 'the pitch'
        $m = New-Market @(
            [pscustomobject]@{ name = 'agentic-board'; description = 'the pitch' },
            [pscustomobject]@{ name = 'agentic-bi-ops'; description = 'DEPRECATED alias' }
        )
        (Test-ManifestConsistency -Plugin $p -Marketplace $m).Consistent | Should -BeTrue
    }

    It 'flags a description that has drifted' {
        $p = New-Plugin 'agentic-board' 'the new pitch'
        $m = New-Market @([pscustomobject]@{ name = 'agentic-board'; description = 'the OLD pitch' })
        $r = Test-ManifestConsistency -Plugin $p -Marketplace $m
        $r.Consistent | Should -BeFalse
        $r.Issues -join ' ' | Should -Match 'drifted'
    }

    It 'flags a missing plugin entry' {
        $p = New-Plugin 'agentic-board' 'x'
        $m = New-Market @([pscustomobject]@{ name = 'something-else'; description = 'x' })
        $r = Test-ManifestConsistency -Plugin $p -Marketplace $m
        $r.Consistent | Should -BeFalse
        $r.Issues -join ' ' | Should -Match 'no plugins\[\] entry'
    }

    It 'ignores the deprecated alias when matching by name' {
        # The alias shares the source but has its own name + description; it must not
        # be mistaken for the canonical entry.
        $p = New-Plugin 'agentic-board' 'canonical'
        $m = New-Market @(
            [pscustomobject]@{ name = 'agentic-bi-ops'; description = 'DEPRECATED' },
            [pscustomobject]@{ name = 'agentic-board';  description = 'canonical' }
        )
        (Test-ManifestConsistency -Plugin $p -Marketplace $m).Consistent | Should -BeTrue
    }
}
