#Requires -Modules Pester
<#  Board-Changelog's release selection must read the type field through the shared vocabulary.

    #676 moved the selection into Select-ChangelogItems; #671 made the type field's name a shared
    vocabulary ('Type' on older boards, 'Task Type' on boards the English preset made, 'Tipo' in
    Spanish). The two were developed side by side, and the selection kept reading the field by its
    literal name 'Type' - which silently classifies every item of a 'Task Type' board as untyped.
    Resolved at merge time; this pins it. #>

BeforeAll {
    $script:Src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'scripts' 'Board-Changelog.ps1') -Raw
    $m = [regex]::Match($script:Src, '(?s)function Select-ChangelogItems \{.*?\r?\n\}\r?\n')
    $script:SelectBody = $m.Value
}

Describe 'Select-ChangelogItems reads the type through the vocabulary (#671 x #676)' {
    It 'finds the function' {
        $script:SelectBody | Should -Not -BeNullOrEmpty
    }
    It 'calls Get-ItemTypeName instead of reading a field named exactly Type' {
        $script:SelectBody | Should -Match 'Get-ItemTypeName'
        $script:SelectBody | Should -Not -Match "field\.name\s+-eq\s+'Type'"
    }
    It 'Get-ItemTypeName understands the field names of all three kinds of board' {
        # Dot-sourcing the script would run it; take just the function and the vocabulary it needs.
        . (Join-Path $PSScriptRoot '..' 'scripts' 'Get-BoardVocabulary.ps1')
        $fn = [regex]::Match($script:Src, '(?s)function Get-ItemTypeName \{.*?\r?\n\}\r?\n').Value
        $fn | Should -Not -BeNullOrEmpty
        Invoke-Expression $fn
        foreach ($field in 'Type', 'Task Type', 'Tipo') {
            $nodes = @([pscustomobject]@{ field = [pscustomobject]@{ name = $field }; name = 'Bug' })
            (Get-ItemTypeName $nodes) | Should -Not -BeNullOrEmpty -Because "a board whose type field is '$field' must still be read"
        }
    }
}
