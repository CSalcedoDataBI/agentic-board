#Requires -Modules Pester
<#  Tests for Board-Plan.ps1 — the /board plan epic creator.

    Side-effecting (creates issues over gh), so it exposes a dot-source guard: with
    $env:ABIOS_BOARDPLAN_DOTSOURCE set it returns after defining the pure body formatter.
    These tests pin Format-EnrichedEpicBody — the enriched epic body that carries the four
    standard items the /board expert auto-mode reads (Research, Role seed, Deliverables,
    Test plan / DoD). An omitted section must render a detectable TBD placeholder so `auto`
    can tell an enriched-but-unfilled plan from a filled one. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Plan.ps1' | Resolve-Path
    $env:ABIOS_BOARDPLAN_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDPLAN_DOTSOURCE = ''
    $script:Placeholder = '_TBD'
}

Describe 'Format-PriorArtGateBlock' {
    It 'renders the ## Prior-art gate heading when PriorArt is provided' {
        $b = Format-PriorArtGateBlock -PriorArt 'Searched: gh search repos wiki; Decision: build'
        $b | Should -Match '## Prior-art gate'
    }

    It 'renders the PriorArt content under the heading' {
        $b = Format-PriorArtGateBlock -PriorArt 'Decision: reference DeepWiki (zero setup)'
        $b | Should -Match 'Decision: reference DeepWiki'
        $b.IndexOf('## Prior-art gate') | Should -BeLessThan ($b.IndexOf('Decision: reference DeepWiki'))
    }

    It 'renders the heading and a skip notice when -NoPriorArt is set' {
        $b = Format-PriorArtGateBlock -NoPriorArt
        $b | Should -Match '## Prior-art gate'
        $b | Should -Match 'Skipped with -NoPriorArt'
    }

    It 'does NOT include a caller-supplied PriorArt string when -NoPriorArt is set' {
        $b = Format-PriorArtGateBlock -PriorArt 'should not appear' -NoPriorArt
        $b | Should -Not -Match 'should not appear'
    }

    It 'trims leading/trailing whitespace from the PriorArt content' {
        $b = Format-PriorArtGateBlock -PriorArt '  trimmed content  '
        $b | Should -Match 'trimmed content'
        $b | Should -Not -Match '  trimmed content  '
    }
}

Describe 'Assert-PriorArtPresent' {
    It 'throws when PriorArt is empty and -NoPriorArt is not set' {
        { Assert-PriorArtPresent -PriorArt '' } | Should -Throw '*prior-art search is required*'
    }

    It 'throws when PriorArt is whitespace and -NoPriorArt is not set' {
        { Assert-PriorArtPresent -PriorArt '   ' } | Should -Throw '*prior-art search is required*'
    }

    It 'does NOT throw when PriorArt has content' {
        { Assert-PriorArtPresent -PriorArt 'Decision: build — no existing tool does X' } | Should -Not -Throw
    }

    It 'does NOT throw when -NoPriorArt is set even if PriorArt is empty' {
        { Assert-PriorArtPresent -PriorArt '' -NoPriorArt } | Should -Not -Throw
    }
}

Describe 'Format-EnrichedEpicBody' {
    It 'renders all five standard headings' {
        $b = Format-EnrichedEpicBody -Goal 'Build X' -Research 'Prior art: Ralph' `
            -RoleSeed 'Expert in Power BI visuals' -Deliverables @('a script','a command') `
            -TestPlan @('CI green','BPA clean')
        $b | Should -Match '## Goal'
        $b | Should -Match '## Research / Prior-art'
        $b | Should -Match '## Expert role \(seed\)'
        $b | Should -Match '## Deliverables'
        $b | Should -Match '## Test plan \(Definition of Done\)'
    }

    It 'embeds the goal, research and role text' {
        $b = Format-EnrichedEpicBody -Goal 'Build X' -Research 'Prior art: Ralph' `
            -RoleSeed 'Expert in Power BI visuals' -Deliverables @('a script') -TestPlan @('CI green')
        $b | Should -Match 'Build X'
        $b | Should -Match 'Prior art: Ralph'
        $b | Should -Match 'Expert in Power BI visuals'
    }

    It 'renders deliverables and test-plan as bullet lists' {
        $b = Format-EnrichedEpicBody -Goal 'g' -Research 'r' -RoleSeed 's' `
            -Deliverables @('first deliverable','second deliverable') -TestPlan @('lint passes')
        $b | Should -Match '- first deliverable'
        $b | Should -Match '- second deliverable'
        $b | Should -Match '- lint passes'
    }

    It 'renders a detectable TBD placeholder for an omitted section' {
        $b = Format-EnrichedEpicBody -Goal 'g'   # research/role/deliverables/testplan omitted
        $b | Should -Match ([regex]::Escape($script:Placeholder))
    }

    It 'a fully-omitted body still has every heading (all TBD)' {
        $b = Format-EnrichedEpicBody
        $b | Should -Match '## Goal'
        $b | Should -Match '## Test plan \(Definition of Done\)'
        ([regex]::Matches($b, [regex]::Escape($script:Placeholder))).Count | Should -BeGreaterOrEqual 5
    }
}

Describe 'Resolve-TextParam (#419 - file-backed parameters)' {
    BeforeAll {
        $script:TmpDir = Join-Path $TestDrive 'resolve-text'
        New-Item -ItemType Directory -Force $script:TmpDir | Out-Null
    }

    It 'returns the inline value when filePath is empty' {
        Resolve-TextParam '' 'inline text' | Should -BeExactly 'inline text'
    }

    It 'returns the inline value when filePath is whitespace-only' {
        Resolve-TextParam '   ' 'inline text' | Should -BeExactly 'inline text'
    }

    It 'reads and returns file content when a valid file is provided' {
        $f = Join-Path $script:TmpDir 'desc.txt'
        Set-Content -Path $f -Value 'content from file' -NoNewline
        Resolve-TextParam $f '' | Should -Match 'content from file'
    }

    It 'treats text containing slash-commands as data (not executed) when loaded from a file' {
        $f = Join-Path $script:TmpDir 'slashes.txt'
        $payload = "/board plan - use /scan and /knowledge to research; see /expert auto"
        Set-Content -Path $f -Value $payload -NoNewline
        $result = Resolve-TextParam $f ''
        $result | Should -Match '/board'
        $result | Should -Match '/scan'
        $result | Should -Match '/knowledge'
    }

    It 'a file with a destructive-looking command is returned as plain text, never executed' {
        $f = Join-Path $script:TmpDir 'destructive.txt'
        Set-Content -Path $f -Value 'Remove-Item /etc/passwd -Force' -NoNewline
        Resolve-TextParam $f '' | Should -BeExactly 'Remove-Item /etc/passwd -Force'
    }

    It 'throws when the file path is set but the file does not exist' {
        { Resolve-TextParam (Join-Path $script:TmpDir 'nonexistent.txt') '' } | Should -Throw "*does not exist*"
    }

    It 'prefers the file when both a file and an inline value are supplied (file wins)' {
        $f = Join-Path $script:TmpDir 'wins.txt'
        Set-Content -Path $f -Value 'from file' -NoNewline
        Resolve-TextParam $f 'inline should be ignored' | Should -BeExactly 'from file'
    }
}
