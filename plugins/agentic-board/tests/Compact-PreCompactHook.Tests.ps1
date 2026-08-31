#Requires -Modules Pester
<#  Pester tests for Compact-PreCompactHook.ps1 - the transcript-snapshot safety net
    (epic #348).

    The hook reads stdin and copies a file, so it exposes a dot-source guard: with
    $env:ABIOS_PRECOMPACT_DOTSOURCE set it returns after defining the pure
    New-CompactSnapshotName helper. These tests exercise only that helper, with a
    FIXED clock so the name is deterministic. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Compact-PreCompactHook.ps1' | Resolve-Path
    $env:ABIOS_PRECOMPACT_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_PRECOMPACT_DOTSOURCE = ''

    $script:T0 = [datetime]'2026-07-17T10:05:09Z'
}

Describe 'New-CompactSnapshotName' {
    It 'is a colon-free UTC stamp with the trigger and .jsonl extension' {
        New-CompactSnapshotName $script:T0 'auto' | Should -BeExactly '20260717T100509Z-auto.jsonl'
    }
    It 'lowercases the trigger' {
        New-CompactSnapshotName $script:T0 'MANUAL' | Should -BeExactly '20260717T100509Z-manual.jsonl'
    }
    It 'falls back to "unknown" for a junk trigger' {
        New-CompactSnapshotName $script:T0 '' | Should -BeExactly '20260717T100509Z-unknown.jsonl'
        New-CompactSnapshotName $script:T0 'a b' | Should -BeExactly '20260717T100509Z-unknown.jsonl'
    }
    It 'never contains a colon (invalid on Windows)' {
        New-CompactSnapshotName $script:T0 'auto' | Should -Not -Match ':'
    }
}
