#Requires -Modules Pester
<#  Pester tests for the capture-in-handoff helper Get-HandoffKnowledgeCandidates in
    Board-Handoff.ps1 (the knowledge anti-rot hook, #162). Dot-sourced via the guard so
    only the pure helper runs — zero gh/git/network. Covers URL extraction from the
    narrative, doc-like key-file filtering + repo-relative normalization, dedup against
    the existing registry, and the code-file exclusion. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Handoff.ps1' | Resolve-Path
    $env:ABIOS_HANDOFF_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_HANDOFF_DOTSOURCE = ''
    function New-Root {
        $r = Join-Path ([IO.Path]::GetTempPath()) ("hocap-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $r 'docs') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $r 'docs' 'research.md') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $r 'src.ps1') -Force | Out-Null
        return $r
    }
}

Describe 'Get-HandoffKnowledgeCandidates' {
    It 'extracts http(s) URLs from the narrative' {
        $c = Get-HandoffKnowledgeCandidates -Narrative @('[V] read https://learn.microsoft.com/fabric for the API') -RepoRoot (New-Root)
        ($c | Where-Object ref -eq 'https://learn.microsoft.com/fabric').type | Should -Be 'url'
    }
    It 'trims trailing punctuation off a URL' {
        $c = Get-HandoffKnowledgeCandidates -Narrative @('see https://x.dev/page.') -RepoRoot (New-Root)
        ($c.ref) | Should -Be 'https://x.dev/page'
    }
    It 'proposes a doc-like key file as a repo-relative forward-slash ref' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -KeyFiles @('docs\research.md') -RepoRoot $root
        ($c | Where-Object type -eq 'md').ref | Should -Be 'docs/research.md'
        Remove-Item $root -Recurse -Force
    }
    It 'proposes an existing folder key file as type folder' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -KeyFiles @('docs') -RepoRoot $root
        ($c | Where-Object ref -eq 'docs').type | Should -Be 'folder'
        Remove-Item $root -Recurse -Force
    }
    It 'excludes non-doc code files' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -KeyFiles @('src.ps1') -RepoRoot $root
        $c | Should -BeNullOrEmpty
        Remove-Item $root -Recurse -Force
    }
    It 'skips key files that do not exist on disk (never invent)' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -KeyFiles @('docs/ghost.md') -RepoRoot $root
        $c | Should -BeNullOrEmpty
        Remove-Item $root -Recurse -Force
    }
    It 'dedups candidates already in the registry' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -Narrative @('https://dup/1') -KeyFiles @('docs/research.md') `
                -RepoRoot $root -KnownRefs @('https://dup/1', 'docs/research.md')
        $c | Should -BeNullOrEmpty
        Remove-Item $root -Recurse -Force
    }
    It 'strips a leading bullet and surrounding backticks from a key file' {
        $root = New-Root
        $c = Get-HandoffKnowledgeCandidates -KeyFiles @('- `docs/research.md` (the notes)') -RepoRoot $root
        ($c | Where-Object type -eq 'md').ref | Should -Be 'docs/research.md'
        Remove-Item $root -Recurse -Force
    }
    It 'returns nothing when there is no material' {
        Get-HandoffKnowledgeCandidates -RepoRoot (New-Root) | Should -BeNullOrEmpty
    }
}
