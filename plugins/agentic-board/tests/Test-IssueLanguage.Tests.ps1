#Requires -Modules Pester
<#  Tests for scripts/Test-IssueLanguage.ps1 (#305).

    A heuristic detector is only worth shipping if its thresholds are pinned, so this asserts BOTH
    directions on every case: Spanish text must flag, and English text must NOT. The one-directional
    version of this test ("it catches Spanish!") is what lets a detector quietly flag everything.

    The English cases are not invented: #8 and #84 are real issues, written in English, that a naive
    marker list flags because they *discuss* Spanish ('todo', 'no'). They are the regression that
    justifies the marker list being as short as it is.

    Measured against the full 173-issue corpus when written: 12 flagged (exactly the Spanish ones),
    161 clean, highest English title score 0, highest English body score 2. #>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'Test-IssueLanguage.ps1' |
        Resolve-Path
    $env:ABIOS_ISSUELANG_DOTSOURCE = '1'
    . $script:ScriptPath
    $env:ABIOS_ISSUELANG_DOTSOURCE = $null
}

Describe 'Test-IssueLanguage' {

    Context 'Spanish is flagged' {
        It 'flags a Spanish title' {
            # Real shape: #295.
            $v = Test-IssueLanguage -Title 'release: la version no se bumpeo tras #279 - el arreglo no llega' -Body ''
            $v.IsEnglish | Should -BeFalse
            $v.Reason    | Should -Match 'title'
        }

        It 'flags a Spanish body even when the title is technical enough to score zero' {
            # Real shape: #298 - the title is mostly a path, the body gives it away.
            $v = Test-IssueLanguage -Title 'knowledge writes registry.json' -Body @'
El script escribe el registry.json en el directorio equivocado cuando la ruta tiene un hook de
lista blanca. Esto hace que el archivo sea inusable, porque cada cambio se pierde. Falta que el
resolver pregunte por la raiz del repo antes de escribir.
'@
            $v.IsEnglish | Should -BeFalse
            $v.Reason    | Should -Match 'body'
        }

        It 'scores accented characters as the strong signal they are' {
            (Get-SpanishScore -Text 'versión') | Should -BeGreaterThan (Get-SpanishScore -Text 'version')
        }
    }

    Context 'English is not flagged' {
        It 'passes an ordinary English issue' {
            $v = Test-IssueLanguage -Title 'work: teardown can fail open when the worktree drifted off its branch' -Body @'
## Problem

Test-WorktreeStillRegistered proves "still registered" with two signals: the branch, and the path as
a secondary. Both can miss the same worktree at once, so the teardown deletes the branch while git
still registers the worktree.

## Fix

Stop comparing strings - let git resolve path identity. If neither signal can prove the worktree is
gone, fail closed.
'@
            $v.IsEnglish | Should -BeTrue
        }

        It 'does not flag an English issue that discusses Spanish (#8 regression)' {
            # 'todo' and 'no' are English words. A marker list containing them flags this.
            $v = Test-IssueLanguage -Title "project-scan: code-marker regex must follow TAG: convention (no Spanish 'todo')" -Body ''
            $v.IsEnglish | Should -BeTrue
        }

        It 'does not flag an English issue about a Spanish false friend (#84 regression)' {
            $v = Test-IssueLanguage -Title "board: rename Status 'Todo' -> 'Backlog' (avoid ES false-friend)" -Body ''
            $v.IsEnglish | Should -BeTrue
        }
    }

    Context 'Code is not prose' {
        It 'ignores Spanish quoted inside a fenced block' {
            # Quoting a Windows PowerShell error is not writing Spanish. This is a real case: the
            # es-ES parse error "Falta el parentesis de cierre" appears in repro output.
            $body = @'
Running the script under Windows PowerShell 5.1 fails to parse:

```
Falta el parentesis de cierre en la llamada al metodo.
No se puede encontrar el archivo porque la ruta esta mal.
```

Use pwsh 7 instead: it reads the file as UTF-8.
'@
            (Test-IssueLanguage -Title 'script fails to parse under Windows PowerShell 5.1' -Body $body).IsEnglish |
                Should -BeTrue
        }

        It 'ignores Spanish inside inline code' {
            (Get-SpanishScore -Text 'the flag `para el archivo` is literal') | Should -Be 0
        }

        It 'strips URLs before scoring' {
            (Get-SpanishScore -Text 'see https://example.com/la/para/el/cada/una') | Should -Be 0
        }
    }

    Context 'Thresholds' {
        It 'exposes the tuned defaults, so a change to them is a visible diff' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
            $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
            $params | Should -Contain 'TitleThreshold'
            $params | Should -Contain 'BodyThreshold'
        }

        It 'honours a caller-supplied threshold' {
            $t = 'release: la version no se bumpeo tras el arreglo'
            (Test-IssueLanguage -Title $t -Body '' -TitleThreshold 99).IsEnglish | Should -BeTrue
            (Test-IssueLanguage -Title $t -Body '' -TitleThreshold 1).IsEnglish  | Should -BeFalse
        }
    }
}
