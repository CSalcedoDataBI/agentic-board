#Requires -Modules Pester
<#  Tests for Find-InternalVocabularyLeak.ps1 — the detector behind the "no internal names in
    user-facing output" regression test (#491/#494). Pure text matching, guarded by
    $env:ABIOS_VOCABLEAK_DOTSOURCE so these run with no filesystem access for the detector half;
    Get-WriteHostArgumentText DOES touch disk (it parses a real .ps1 file) and is tested against
    small temp scripts written for the purpose. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Find-InternalVocabularyLeak.ps1' | Resolve-Path
    $env:ABIOS_VOCABLEAK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_VOCABLEAK_DOTSOURCE = ''
}

Describe 'Find-InternalVocabularyLeak — script filenames (#494)' {
    It 'flags this codebase''s own Verb-Noun.ps1 naming convention' {
        $hits = Find-InternalVocabularyLeak -Text 'Siguiente paso: Board-Work.ps1 -Start <n>'
        @($hits | Where-Object Kind -eq 'ScriptFilename').Match | Should -Contain 'Board-Work.ps1'
    }
    It 'flags a multi-hyphen filename' {
        $hits = Find-InternalVocabularyLeak -Text 'ver Tmdl-Diff-Review.ps1'
        @($hits | Where-Object Kind -eq 'ScriptFilename').Match | Should -Contain 'Tmdl-Diff-Review.ps1'
    }
    It 'flags .psm1 and .psd1 the same way' {
        (Find-InternalVocabularyLeak -Text 'Board-Helpers.psm1').Kind | Should -Contain 'ScriptFilename'
        (Find-InternalVocabularyLeak -Text 'Board-Manifest.psd1').Kind | Should -Contain 'ScriptFilename'
    }
    It 'does NOT flag a typed command mention' {
        (Find-InternalVocabularyLeak -Text 'Siguiente paso: /board work -Start <n>').Count | Should -Be 0
    }
    It 'does NOT flag ordinary prose with no filename shape' {
        (Find-InternalVocabularyLeak -Text 'PR listo, revisalo cuando quieras').Count | Should -Be 0
    }
}

Describe 'Find-InternalVocabularyLeak — bare extensions (#494)' {
    It 'flags a standalone .ps1 mention with no filename attached' {
        $hits = Find-InternalVocabularyLeak -Text 'the .ps1 file is missing'
        @($hits | Where-Object Kind -eq 'BareExtension').Match | Should -Contain '.ps1'
    }
    It 'does NOT double-count the extension when it is already part of a filename hit' {
        $hits = Find-InternalVocabularyLeak -Text 'Board-Work.ps1'
        @($hits | Where-Object Kind -eq 'BareExtension').Count | Should -Be 0
        @($hits | Where-Object Kind -eq 'ScriptFilename').Count | Should -Be 1
    }
}

Describe 'Find-InternalVocabularyLeak — version-pinned cache paths (#494)' {
    It 'flags a plugin cache path pinned to a version' {
        $hits = Find-InternalVocabularyLeak -Text 'C:\Users\me\.claude\plugins\cache\agentic-board\agentic-board\0.37.0\scripts\Board-Work.ps1'
        @($hits | Where-Object Kind -eq 'CachePath').Count | Should -BeGreaterThan 0
    }
    It 'a cache path containing a script name is flagged for BOTH reasons - it is doubly wrong' {
        $hits = Find-InternalVocabularyLeak -Text '~/.claude/plugins/cache/agentic-board/agentic-board/0.37.0/scripts/New-BoardPR.ps1'
        $hits.Kind | Should -Contain 'CachePath'
        $hits.Kind | Should -Contain 'ScriptFilename'
    }
    It 'does NOT flag an unpinned, non-cache path' {
        (Find-InternalVocabularyLeak -Text 'C:\Users\me\Repos\agentic-board\README.md').Count | Should -Be 0
    }
}

Describe 'Find-InternalVocabularyLeak — clean text (#494)' {
    It 'returns nothing for text with no internal vocabulary at all' {
        Find-InternalVocabularyLeak -Text 'Todo listo, sin nombres internos ni rutas raras.' | Should -BeNullOrEmpty
    }
    It 'returns nothing for an empty or whitespace string' {
        Find-InternalVocabularyLeak -Text '' | Should -BeNullOrEmpty
        Find-InternalVocabularyLeak -Text '   ' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WriteHostArgumentText — AST extraction, not line-regex (#494)' {
    BeforeAll {
        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vocableak-" + [guid]::NewGuid().ToString('N') + ".ps1")
    }
    AfterAll { if (Test-Path $script:Tmp) { Remove-Item $script:Tmp -Force } }

    It 'extracts a plain string argument, with its line number' {
        'Write-Host "hola Board-Work.ps1 mundo" -ForegroundColor Cyan' | Set-Content -Path $script:Tmp -Encoding utf8
        $args = @(Get-WriteHostArgumentText -Path $script:Tmp)
        $args.Count | Should -Be 1
        $args[0].Line | Should -Be 1
        $args[0].Text | Should -Match 'Board-Work\.ps1'
    }
    It 'never mistakes a -ForegroundColor VALUE for message text' {
        'Write-Host "clean text" -ForegroundColor DarkGray' | Set-Content -Path $script:Tmp -Encoding utf8
        $args = @(Get-WriteHostArgumentText -Path $script:Tmp)
        $args.Count | Should -Be 1
        $args[0].Text | Should -Not -Match 'DarkGray'
    }
    It 'extracts the FULL -f format-string expression, not just the literal part' {
        'Write-Host ("Wave {0}: Board-Work.ps1" -f $w) -ForegroundColor Gray' | Set-Content -Path $script:Tmp -Encoding utf8
        $args = @(Get-WriteHostArgumentText -Path $script:Tmp)
        $args[0].Text | Should -Match 'Board-Work\.ps1'
    }
    It 'reports one entry per Write-Host call across multiple lines' {
        @'
Write-Host "linea uno"
Write-Host "linea dos"
'@ | Set-Content -Path $script:Tmp -Encoding utf8
        $args = @(Get-WriteHostArgumentText -Path $script:Tmp)
        $args.Count | Should -Be 2
        $args[1].Line | Should -Be 2
    }
    It 'returns nothing for a file with no Write-Host calls' {
        'Write-Output "not Write-Host"' | Set-Content -Path $script:Tmp -Encoding utf8
        Get-WriteHostArgumentText -Path $script:Tmp | Should -BeNullOrEmpty
    }
}
