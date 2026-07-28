#Requires -Modules Pester
<#  Tests for Board-Summary.ps1 — the closing summary every user-facing flow must end with.

    The contract is four blocks, always the same four, always in the same order: what I found,
    what I did, what is left, what I need from you. These pin the parts a user depends on:
    the fixed order (so the eye learns where to look), the explicit sentence an empty block
    renders (silence is unreadable — "nothing" has to be said out loud), and the fact that
    "need from you" never renders blank, because that is the only block that asks the reader
    to act. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Summary.ps1' | Resolve-Path
    $env:ABIOS_BOARDSUMMARY_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDSUMMARY_DOTSOURCE = ''

    $script:Full = @{
        Title       = 'Trabajo terminado en #492'
        Found       = @('La rama local estaba 2 commits atras de main')
        Did         = @('Cree el resumen de cierre', 'Agregue 12 pruebas')
        Pending     = @('Aplicarlo a los demas comandos (#493)')
        NeedFromYou = @('Revisar y mergear el PR')
    }
}

Describe 'Format-ClosingSummary — the four blocks' {
    It 'renders all four blocks even when only one has content' {
        $s = Format-ClosingSummary -Did @('algo')
        foreach ($h in 'Que encontre', 'Que hice', 'Que queda pendiente', 'Que necesito de ti') {
            $s | Should -Match ([regex]::Escape($h))
        }
    }

    It 'keeps the four blocks in the contract order, whatever order the caller passes them' {
        $s = Format-ClosingSummary -NeedFromYou @('d') -Pending @('c') -Did @('b') -Found @('a')
        $idxFound   = $s.IndexOf('Que encontre')
        $idxDid     = $s.IndexOf('Que hice')
        $idxPending = $s.IndexOf('Que queda pendiente')
        $idxNeed    = $s.IndexOf('Que necesito de ti')
        $idxFound   | Should -BeLessThan $idxDid
        $idxDid     | Should -BeLessThan $idxPending
        $idxPending | Should -BeLessThan $idxNeed
    }

    It 'renders one bullet per item' {
        $s = Format-ClosingSummary @script:Full
        $bullets = @(($s -split "`n") | Where-Object { $_ -match '^\s*-\s' })
        $bullets.Count | Should -Be 5
        $s | Should -Match 'Agregue 12 pruebas'
    }

    It 'heads the summary with the title when one is given' {
        (Format-ClosingSummary @script:Full) | Should -Match 'Trabajo terminado en #492'
    }

    It 'renders without a title too' {
        { Format-ClosingSummary -Did @('algo') } | Should -Not -Throw
    }
}

Describe 'Format-ClosingSummary — an empty block says so out loud' {
    It 'never leaves a block blank: every empty block gets an explicit sentence' {
        $s = Format-ClosingSummary
        # No block may be followed immediately by the next block's heading.
        $s | Should -Not -Match 'Que encontre\s*\r?\n\s*\r?\n?\s*Que hice'
        # Four blocks, four "nothing" sentences.
        @(($s -split "`n") | Where-Object { $_ -match '^\s*-\s' }).Count | Should -Be 4
    }

    It 'states plainly that nothing is expected from the reader when that block is empty' {
        $s = Format-ClosingSummary -Did @('algo')
        # The reader must be able to close the terminal knowing they owe nothing.
        $s | Should -Match '(?s)Que necesito de ti.*Nada'
    }

    It 'still asks for action when the block has content' {
        $s = Format-ClosingSummary -NeedFromYou @('Revisar el PR')
        $s | Should -Match 'Revisar el PR'
        $s | Should -Not -Match '(?s)Que necesito de ti.*Nada'
    }
}

Describe 'Format-ClosingSummary — the two renderings' {
    It 'renders plain text for the terminal, with no markdown headings' {
        $s = Format-ClosingSummary @script:Full
        $s | Should -Not -Match '(?m)^#'
        $s | Should -Not -Match '<!--'
    }

    It 'renders markdown with headings and a durable marker for PR bodies and comments' {
        $s = Format-ClosingSummary @script:Full -AsMarkdown
        $s | Should -Match '\[abios-summary\]'
        $s | Should -Match '(?m)^##\s'
    }

    It 'carries the same content in both renderings' {
        $plain = Format-ClosingSummary @script:Full
        $md    = Format-ClosingSummary @script:Full -AsMarkdown
        foreach ($item in 'Agregue 12 pruebas', 'Revisar y mergear el PR') {
            $plain | Should -Match ([regex]::Escape($item))
            $md    | Should -Match ([regex]::Escape($item))
        }
    }
}

Describe 'Format-ClosingSummary — shape' {
    It 'returns one string, not an array of lines' {
        (Format-ClosingSummary @script:Full) | Should -BeOfType [string]
    }

    It 'leaves no trailing blank line or trailing whitespace' {
        $s = Format-ClosingSummary @script:Full
        $s | Should -Not -Match '\s$'
    }

    It 'accepts a single string where a list is expected' {
        $s = Format-ClosingSummary -Did 'una sola cosa'
        $s | Should -Match 'una sola cosa'
    }
}
