#Requires -Modules Pester
<#  Directory size gate (#759).

    The Anthropic plugin directory rejects any non-image file over 256 KiB and holds plugins with
    more than 512 files for manual review. Board-Work.ps1 crossed 256 KiB once by growing one
    feature at a time, so this fails at 240 KiB - a margin to split a file before it blocks a
    submission, not after. Local eval output (evals/results, gitignored) is not shipped and is skipped.  #>

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:Files = @(Get-ChildItem -LiteralPath $script:PluginRoot -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\/]evals[\/]results[\/]' })
}

Describe 'Plugin folder stays inside the directory limits (#759)' {
    It 'no file is over 240 KiB (the directory limit is 256 KiB)' {
        $big = @($script:Files | Where-Object { $_.Length -gt 240KB } |
            ForEach-Object { '{0} ({1:N0} bytes)' -f $_.FullName.Substring($script:PluginRoot.Length + 1), $_.Length })
        $big | Should -BeNullOrEmpty -Because 'split the file into dot-sourced BoardWork.*.ps1-style parts before it reaches 256 KiB'
    }
    It 'holds at most 512 files' {
        $script:Files.Count | Should -BeLessOrEqual 512
    }
}
