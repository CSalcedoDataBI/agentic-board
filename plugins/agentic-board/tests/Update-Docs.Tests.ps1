#Requires -Modules Pester
<#  Pester tests for Update-Docs.ps1 - README docs generator (#202).

    Update-Docs.ps1 is side-effecting (reads command files + plugin.json, rewrites
    README). It exposes a dot-source guard: with $env:ABIOS_DOCS_DOTSOURCE set it
    returns after defining the pure helpers without touching disk. These tests
    exercise the pure frontmatter/catalog/marker logic. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Update-Docs.ps1' | Resolve-Path
    $env:ABIOS_DOCS_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_DOCS_DOTSOURCE = ''
}

Describe 'Get-FrontmatterField' {
    It 'extracts a field from a frontmatter block' {
        $raw = "---`ndescription: Do the thing`n---`nbody"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -Be 'Do the thing'
    }
    It 'trims surrounding whitespace from the value' {
        $raw = "---`ndescription:    padded value   `n---`n"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -Be 'padded value'
    }
    It 'tolerates CRLF line endings' {
        $raw = "---`r`ndescription: crlf value`r`n---`r`nbody"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -Be 'crlf value'
    }
    It 'preserves an em dash in the value' {
        $raw = "---`ndescription: a dash " + [char]0x2014 + " here`n---"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -Be ("a dash " + [char]0x2014 + " here")
    }
    It 'returns null when the field is absent' {
        $raw = "---`nname: x`n---"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -BeNullOrEmpty
    }
    It 'returns null when there is no frontmatter block' {
        Get-FrontmatterField -Raw "no frontmatter here" -Field 'description' | Should -BeNullOrEmpty
    }
    It 'does not read a field from the body outside the fence' {
        $raw = "---`nname: x`n---`ndescription: in the body"
        Get-FrontmatterField -Raw $raw -Field 'description' | Should -BeNullOrEmpty
    }
}

Describe 'Get-CommandCatalog' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ("cmds_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }
    It 'builds a /command + description row per file, sorted by name' {
        Set-Content -Path (Join-Path $dir 'scan.md')  -Value "---`ndescription: Scan things`n---" -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'board.md') -Value "---`ndescription: Run the board`n---" -Encoding UTF8
        $rows = Get-CommandCatalog -CommandsDir $dir
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be '/board'   # sorted
        $rows[0].Description | Should -Be 'Run the board'
        $rows[1].Name | Should -Be '/scan'
    }
    It 'skips a command file that has no description' {
        Set-Content -Path (Join-Path $dir 'good.md') -Value "---`ndescription: Has one`n---" -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'bare.md') -Value "no frontmatter at all" -Encoding UTF8
        $rows = Get-CommandCatalog -CommandsDir $dir
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be '/good'
    }
    It 'throws when the commands directory does not exist' {
        { Get-CommandCatalog -CommandsDir (Join-Path $TestDrive 'nope') } | Should -Throw
    }
}

Describe 'Format-CatalogTable' {
    It 'renders a header plus one row per command' {
        $rows = @(
            [pscustomobject]@{ Name = '/board'; Description = 'Run the board' },
            [pscustomobject]@{ Name = '/scan';  Description = 'Scan things' }
        )
        $out = Format-CatalogTable -Rows $rows
        $lines = $out -split "`n"
        $lines[0] | Should -Be '| Command | What it does |'
        $lines[1] | Should -Be '|---|---|'
        $lines[2] | Should -Be '| `/board` | Run the board |'
        $lines[3] | Should -Be '| `/scan` | Scan things |'
    }
    It 'escapes a pipe inside a description so the table is not broken' {
        $rows = @([pscustomobject]@{ Name = '/x'; Description = 'a | b' })
        (Format-CatalogTable -Rows $rows) -split "`n" | Select-Object -Last 1 |
            Should -Be '| `/x` | a \| b |'
    }
    It 'does not double-escape a pipe an author already escaped' {
        $rows = @([pscustomobject]@{ Name = '/x'; Description = 'a \| b' })
        (Format-CatalogTable -Rows $rows) -split "`n" | Select-Object -Last 1 |
            Should -Be '| `/x` | a \| b |'
    }
    It 'renders just the header for an empty catalog' {
        (Format-CatalogTable -Rows @()) | Should -Be "| Command | What it does |`n|---|---|"
    }
}

Describe 'Get-DominantNewline' {
    It 'returns CRLF when the text contains a CRLF' {
        Get-DominantNewline -Text "a`r`nb" | Should -Be "`r`n"
    }
    It 'returns LF for LF-only text' {
        Get-DominantNewline -Text "a`nb" | Should -Be "`n"
    }
    It 'returns LF for text with no newline at all' {
        Get-DominantNewline -Text 'single line' | Should -Be "`n"
    }
}

Describe 'Get-PluginVersion' {
    It 'extracts the version from minified plugin.json text' {
        Get-PluginVersion -Raw '{"name":"x","version":"0.18.0"}' | Should -Be '0.18.0'
    }
    It 'throws when there is no version field' {
        { Get-PluginVersion -Raw '{"name":"x"}' } | Should -Throw
    }
}

Describe 'Set-MarkedRegion' {
    It 'replaces only the content between the markers, preserving the rest' {
        $t = "before`n<!-- BEGIN:x -->OLD<!-- END:x -->`nafter"
        Set-MarkedRegion -Text $t -Name 'x' -Content 'NEW' |
            Should -Be "before`n<!-- BEGIN:x -->NEW<!-- END:x -->`nafter"
    }
    It 'keeps a trailing note on the BEGIN marker' {
        $t = "<!-- BEGIN:x - do not edit -->old<!-- END:x -->"
        Set-MarkedRegion -Text $t -Name 'x' -Content 'new' |
            Should -Be "<!-- BEGIN:x - do not edit -->new<!-- END:x -->"
    }
    It 'replaces a multi-line region' {
        $t = "a`n<!-- BEGIN:t -->`nline1`nline2`n<!-- END:t -->`nz"
        Set-MarkedRegion -Text $t -Name 't' -Content "`nNEW`n" |
            Should -Be "a`n<!-- BEGIN:t -->`nNEW`n<!-- END:t -->`nz"
    }
    It 'splices content literally (a $ in the content is not a regex backreference)' {
        $t = "<!-- BEGIN:x -->old<!-- END:x -->"
        Set-MarkedRegion -Text $t -Name 'x' -Content '$1 and ${2}' |
            Should -Be '<!-- BEGIN:x -->$1 and ${2}<!-- END:x -->'
    }
    It 'preserves an em dash spliced into the region' {
        $dash = [char]0x2014
        $t = "<!-- BEGIN:x -->old<!-- END:x -->"
        Set-MarkedRegion -Text $t -Name 'x' -Content "a $dash b" |
            Should -Be "<!-- BEGIN:x -->a $dash b<!-- END:x -->"
    }
    It 'throws when the marker region is missing' {
        { Set-MarkedRegion -Text 'no markers' -Name 'x' -Content 'y' } | Should -Throw
    }
    It 'throws when the region name appears more than once (ambiguous)' {
        $t = "<!-- BEGIN:x -->a<!-- END:x --> <!-- BEGIN:x -->b<!-- END:x -->"
        { Set-MarkedRegion -Text $t -Name 'x' -Content 'y' } | Should -Throw
    }
    It 'throws on a stray extra BEGIN inside the region (would be silently swallowed)' {
        $t = "<!-- BEGIN:x -->old<!-- BEGIN:x -->more<!-- END:x -->"
        { Set-MarkedRegion -Text $t -Name 'x' -Content 'y' } | Should -Throw
    }
    It 'throws on a stray trailing END (would be left behind)' {
        $t = "<!-- BEGIN:x -->old<!-- END:x --><!-- END:x -->"
        { Set-MarkedRegion -Text $t -Name 'x' -Content 'y' } | Should -Throw
    }
    It 'throws when the markers are out of order (END before BEGIN)' {
        $t = "<!-- END:x -->old<!-- BEGIN:x -->"
        { Set-MarkedRegion -Text $t -Name 'x' -Content 'y' } | Should -Throw
    }
    It 'is idempotent: re-running with the same content is a no-op' {
        $t = "<!-- BEGIN:x -->A<!-- END:x -->"
        $once  = Set-MarkedRegion -Text $t    -Name 'x' -Content 'B'
        $twice = Set-MarkedRegion -Text $once -Name 'x' -Content 'B'
        $twice | Should -Be $once
    }
}

Describe 'Format-ClosingSummaryPrompt (#493)' {
    BeforeAll {
        $script:SampleBlocks = @(
            [pscustomobject]@{ Key = 'Found'; Label = 'Que encontre'; Empty = 'Nada fuera de lo esperado.' }
            [pscustomobject]@{ Key = 'Did';   Label = 'Que hice';     Empty = 'Nada - no se cambio nada.' }
        )
    }
    It 'renders one numbered row per block, in the order given' {
        $out = Format-ClosingSummaryPrompt -Blocks $script:SampleBlocks
        $out | Should -Match '(?m)^\| 1 \| \*\*Que encontre\*\* \|'
        $out | Should -Match '(?m)^\| 2 \| \*\*Que hice\*\* \|'
        ([regex]::Matches($out, '(?m)^\| \d+ \|')).Count | Should -Be 2
    }
    It 'carries each block''s when-empty sentence, so the prompt and the renderer agree' {
        $out = Format-ClosingSummaryPrompt -Blocks $script:SampleBlocks
        foreach ($b in $script:SampleBlocks) { $out | Should -BeLike "*$($b.Empty)*" }
    }
    It 'tells the reader never to drop a block' {
        Format-ClosingSummaryPrompt -Blocks $script:SampleBlocks | Should -Match '(?i)never drop'
    }
    It 'points edits at the renderer instead of the generated text' {
        Format-ClosingSummaryPrompt -Blocks $script:SampleBlocks | Should -Match '(?i)change the'
    }
    It 'throws on an empty contract instead of emitting an empty instruction' {
        # A silently empty block is the exact failure this whole epic removes; generating an
        # instruction with no blocks in it would reintroduce it one level up.
        { Format-ClosingSummaryPrompt -Blocks @() } | Should -Throw
    }
}

Describe 'Get-CommandRegionPlan (#493)' {
    BeforeAll {
        $script:Prompt = "LINE ONE`nLINE TWO"
        $script:Region = '<!-- BEGIN:closing-summary --><!-- END:closing-summary -->'
    }
    It 'plans a write for a file whose region is empty' {
        $plan = Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = "head`n$script:Region`ntail" }) -Prompt $script:Prompt
        $plan.Writes.Count  | Should -Be 1
        $plan.Missing.Count | Should -Be 0
        $plan.Writes[0].Name | Should -Be 'a.md'
        $plan.Writes[0].Text | Should -BeLike '*LINE ONE*'
        $plan.Writes[0].Text | Should -BeLike '*head*'   # everything outside the markers survives
        $plan.Writes[0].Text | Should -BeLike '*tail*'
    }
    It 'reports a file with NO markers as missing instead of silently skipping it' {
        # The whole point: a newly added command with no region must fail loudly, or it ships
        # with no closing contract and nothing notices.
        $plan = Get-CommandRegionPlan -Files @(@{ Name = 'new.md'; Text = 'a command with no region' }) -Prompt $script:Prompt
        @($plan.Missing.Name) | Should -Be @('new.md')
        $plan.Writes.Count | Should -Be 0
    }
    It 'plans nothing for a file already carrying the current content (idempotent)' {
        $first = (Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = "x`n$script:Region`ny" }) -Prompt $script:Prompt).Writes[0].Text
        $again = Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = $first }) -Prompt $script:Prompt
        $again.Writes.Count  | Should -Be 0
        $again.Missing.Count | Should -Be 0
    }
    It 'plans a rewrite when the prompt changed (renderer drift reaches the command files)' {
        $first = (Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = "x`n$script:Region`ny" }) -Prompt $script:Prompt).Writes[0].Text
        $drift = Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = $first }) -Prompt 'A DIFFERENT CONTRACT'
        $drift.Writes.Count | Should -Be 1
        $drift.Writes[0].Text | Should -BeLike '*A DIFFERENT CONTRACT*'
        $drift.Writes[0].Text | Should -Not -BeLike '*LINE ONE*'
    }
    It 'emits the region in the file''s own newline, so a CRLF working copy is not always stale' {
        $crlf = (Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = "x`r`n$script:Region`r`ny" }) -Prompt $script:Prompt).Writes[0].Text
        $crlf | Should -BeLike "*LINE ONE`r`nLINE TWO*"
        $lf   = (Get-CommandRegionPlan -Files @(@{ Name = 'a.md'; Text = "x`n$script:Region`ny" }) -Prompt $script:Prompt).Writes[0].Text
        $lf   | Should -BeLike "*LINE ONE`nLINE TWO*"
        $lf   | Should -Not -BeLike "*LINE ONE`r`n*"
    }
    It 'separates the two verdicts across a mixed batch' {
        $plan = Get-CommandRegionPlan -Prompt $script:Prompt -Files @(
            @{ Name = 'ok.md';      Text = "a`n$script:Region`nb" }
            @{ Name = 'missing.md'; Text = 'no region here' }
        )
        @($plan.Writes.Name)  | Should -Be @('ok.md')
        @($plan.Missing.Name) | Should -Be @('missing.md')
    }
    It 'returns two empty lists for an empty batch instead of throwing' {
        $plan = Get-CommandRegionPlan -Files @() -Prompt $script:Prompt
        $plan.Writes.Count  | Should -Be 0
        $plan.Missing.Count | Should -Be 0
    }
    It 'treats an unterminated region (BEGIN with no END) as unusable' {
        $plan = Get-CommandRegionPlan -Prompt $script:Prompt -Files @(
            @{ Name = 'open.md'; Text = "head`n<!-- BEGIN:closing-summary -->`ntail" }
        )
        @($plan.Missing.Name) | Should -Be @('open.md')
        $plan.Missing[0].Reason | Should -Match 'Malformed'
        $plan.Writes.Count | Should -Be 0
    }
    It 'treats a malformed region (two BEGINs) as missing rather than mangling the file' {
        $bad  = "<!-- BEGIN:closing-summary --><!-- BEGIN:closing-summary --><!-- END:closing-summary -->"
        $plan = Get-CommandRegionPlan -Files @(@{ Name = 'bad.md'; Text = $bad }) -Prompt $script:Prompt
        @($plan.Missing.Name) | Should -Be @('bad.md')
        $plan.Missing[0].Reason | Should -Match 'Malformed' -Because 'reporting a duplicated marker as ''missing'' sends the reader hunting for an absent one'
    }
}
