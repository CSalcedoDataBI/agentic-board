#Requires -Modules Pester
<#  Pester tests for the diagram-authoring skill (#376) and the Diagrams knowledge domain (#378).

    Asserts the skill exists as an INTERNAL support skill (never a typed command), and that the
    knowledge registry carries the Diagrams domain refs + the Graphify catalogue entry.
#>

BeforeAll {
    $script:PluginRoot = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' | Resolve-Path
    $script:RepoRoot   = Join-Path $PSScriptRoot '..' '..' | Resolve-Path
    $script:SkillMd    = Join-Path $script:PluginRoot 'skills' 'diagram-authoring' 'SKILL.md'
    $script:CommandMd  = Join-Path $script:PluginRoot 'commands' 'diagram-authoring.md'
    $script:RegPath    = Join-Path $script:RepoRoot 'knowledge' 'registry.json'

    function Get-Frontmatter([string]$Path) {
        $lines = Get-Content -LiteralPath $Path
        $fm = @{}
        if ($lines[0] -eq '---') {
            for ($i = 1; $i -lt $lines.Count -and $lines[$i] -ne '---'; $i++) {
                if ($lines[$i] -match '^\s*([a-zA-Z-]+):\s*(.*)$') { $fm[$matches[1]] = $matches[2] }
            }
        }
        $fm
    }
}

Describe 'diagram-authoring skill' {
    It 'SKILL.md exists' {
        Test-Path $script:SkillMd | Should -BeTrue
    }

    It 'is an internal skill (user-invocable: false)' {
        $fm = Get-Frontmatter $script:SkillMd
        $fm['user-invocable'] | Should -Be 'false'
    }

    It 'has name diagram-authoring' {
        (Get-Frontmatter $script:SkillMd)['name'] | Should -Be 'diagram-authoring'
    }

    It 'has a non-empty description carrying triggers' {
        $desc = (Get-Frontmatter $script:SkillMd)['description']
        [string]::IsNullOrWhiteSpace($desc) | Should -BeFalse
        $desc | Should -Match 'Triggers'
        $desc | Should -Match 'Mermaid'
    }

    It 'is NOT exposed as a typed command (no commands/diagram-authoring.md)' {
        Test-Path $script:CommandMd | Should -BeFalse -Because 'diagram-authoring is internal — invoked by the model, never typed as /diagram-authoring'
    }

    It 'states the core rule: Mermaid over ASCII' {
        $body = Get-Content -LiteralPath $script:SkillMd -Raw
        $body | Should -Match 'Mermaid'
        $body | Should -Match '(?i)ASCII'
        $body | Should -Match '(?i)Kroki'
    }
}

Describe 'diagram-authoring house theme' {
    BeforeAll {
        $script:ThemePath  = Join-Path $script:PluginRoot 'skills' 'diagram-authoring' 'theme.json'
        $script:StylePath  = Join-Path $script:PluginRoot 'skills' 'diagram-authoring' 'references' 'house-style.md'
        $script:ScriptPath = Join-Path $script:PluginRoot 'scripts' 'Diagram-Theme.ps1'
        $env:ABIOS_DIAGRAMTHEME_DOTSOURCE = '1'
        . $script:ScriptPath
        Remove-Item Env:ABIOS_DIAGRAMTHEME_DOTSOURCE
        $script:Theme = Get-DiagTheme -Path $script:ThemePath

        function Get-MermaidBlocks([string]$Path) {
            $text = (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"
            [regex]::Matches($text, '(?ms)^```mermaid\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value }
        }
    }

    It 'theme.json has the same classes in light and dark' {
        $light = @($script:Theme.light.classes.PSObject.Properties.Name) | Sort-Object
        $dark  = @($script:Theme.dark.classes.PSObject.Properties.Name) | Sort-Object
        $light | Should -Be $dark
        $light | Should -Contain 'frame'
        $light | Should -Contain 'card'
    }

    It 'no class reuses a Mermaid SVG class name' {
        foreach ($c in $script:Theme.light.classes.PSObject.Properties.Name) {
            $c | Should -Not -BeIn @('root', 'node', 'nodes', 'cluster', 'clusters', 'edge', 'edgePaths', 'label') -Because 'classDef root also matches <g class="root"> and fills every arrow'
        }
    }

    It 'the font names no hyphenated generic (Mermaid drops it and falls back to serif)' {
        foreach ($mode in 'light', 'dark') {
            $script:Theme.$mode.themeVariables.fontFamily | Should -Not -Match '(sans-serif|system-ui|-apple-system)'
        }
    }

    It 'header for a flowchart carries the init and the classes' {
        $h = Get-DiagHeader -Theme $script:Theme
        $h | Should -Match '^%%\{init: \{"theme":"base"'
        $h | Should -Match "`nflowchart TB`n"
        $h | Should -Match 'classDef frame '
        $h | Should -Not -Match 'themeCSS' -Because 'GitHub strips themeCSS from an inline init'
    }

    It 'header for another type carries no classDef' {
        $h = Get-DiagHeader -Theme $script:Theme -Type 'sequenceDiagram'
        $h | Should -Match "`nsequenceDiagram$"
        $h | Should -Not -Match 'classDef'
    }

    It 'every mermaid block in the skill and its reference opens with the current header' {
        $init = Get-DiagInit -Theme $script:Theme -Mode light
        foreach ($path in $script:SkillMd, $script:StylePath) {
            $blocks = @(Get-MermaidBlocks $path)
            $blocks.Count | Should -BeGreaterThan 0
            foreach ($b in $blocks) {
                ($b -split "`n")[0] | Should -Be $init -Because "$path must use the theme from theme.json, not loose colors"
            }
        }
    }

    It 'flowchart blocks in the skill use only theme classes and a frame card' {
        $known = @($script:Theme.light.classes.PSObject.Properties.Name)
        foreach ($path in $script:SkillMd, $script:StylePath) {
            foreach ($b in @(Get-MermaidBlocks $path) | Where-Object { $_ -match "`nflowchart " }) {
                $b | Should -Match '(?m)^\s+class \S+ frame$'
                foreach ($m in [regex]::Matches($b, '(?m)^\s+class \S+ (\w+)$')) { $m.Groups[1].Value | Should -BeIn $known }
            }
        }
    }

    It 'the skill covers type choice, inline vs SVG and the GitHub limits' {
        $body = Get-Content -LiteralPath $script:SkillMd -Raw
        foreach ($k in 'architecture-beta', 'mindmap', 'timeline', 'sequenceDiagram', '<picture>', 'Diagram-Theme.ps1', 'layout: elk') {
            $body | Should -Match ([regex]::Escape($k))
        }
    }
}

Describe 'Diagram-Theme.ps1 stamps' {
    BeforeAll {
        $env:ABIOS_DIAGRAMTHEME_DOTSOURCE = '1'
        . (Join-Path $script:PluginRoot 'scripts' 'Diagram-Theme.ps1')
        Remove-Item Env:ABIOS_DIAGRAMTHEME_DOTSOURCE
        $script:Theme = Get-DiagTheme -Path (Join-Path $script:PluginRoot 'skills' 'diagram-authoring' 'theme.json')
    }

    BeforeEach {
        $script:Mmd = Join-Path $TestDrive 'x.mmd'
        Set-Content -LiteralPath $script:Mmd "flowchart TB`n    a --> b" -NoNewline -Encoding utf8
        $script:Light = Join-Path $TestDrive 'x-light.svg'
        $stamp = Get-DiagSourceStamp -Body (Get-Content $script:Mmd -Raw) -Theme $script:Theme -Mode light
        Set-Content -LiteralPath $script:Light (Set-DiagStamp -Svg '<svg>a</svg>' -SourceStamp $stamp) -NoNewline -Encoding utf8
    }

    It 'a freshly stamped SVG is current' {
        Test-DiagSvg -Mmd $script:Mmd -Svg $script:Light -Theme $script:Theme -Mode light | Should -BeNullOrEmpty
    }

    It 'flags a missing SVG' {
        Test-DiagSvg -Mmd $script:Mmd -Svg (Join-Path $TestDrive 'x-dark.svg') -Theme $script:Theme -Mode dark | Should -Match '^missing'
    }

    It 'flags an SVG edited by hand' {
        (Get-Content $script:Light -Raw) -replace '>a<', '>b<' | Set-Content -LiteralPath $script:Light -NoNewline -Encoding utf8
        Test-DiagSvg -Mmd $script:Mmd -Svg $script:Light -Theme $script:Theme -Mode light | Should -Match '^edited by hand'
    }

    It 'flags a stale SVG when the source changes' {
        Set-Content -LiteralPath $script:Mmd "flowchart TB`n    a --> c" -NoNewline -Encoding utf8
        Test-DiagSvg -Mmd $script:Mmd -Svg $script:Light -Theme $script:Theme -Mode light | Should -Match '^stale'
    }

    It 'the themed source puts the init first and the classes after the type line' {
        $src = Get-DiagThemedSource -Body "%%{init: {}}%%`nflowchart TB`n    a --> b" -Theme $script:Theme -Mode dark
        $lines = $src -split "`n"
        $lines[0] | Should -Match '^%%\{init: .*"htmlLabels":false'
        @($lines | Where-Object { $_ -match '^%%\{\s*init' }).Count | Should -Be 1 -Because "the .mmd's own init is dropped"
        $lines[1] | Should -Be 'flowchart TB'
        $lines[2] | Should -Match '^    classDef '
    }

    It 'every committed diagram SVG in the repo is current (what CI checks)' {
        @(Test-DiagRepo -Root $script:RepoRoot.Path -Theme $script:Theme) | Should -BeNullOrEmpty
    }

    It 'the README shows the how-it-works diagram in light and dark' {
        $readme = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Raw
        $readme | Should -Match 'prefers-color-scheme: dark\)" srcset="\.github/assets/diagrams/how-it-works-dark\.svg"'
        $readme | Should -Match 'src="\.github/assets/diagrams/how-it-works-light\.svg"'
    }
}

Describe 'Diagrams knowledge domain' {
    BeforeEach {
        $script:reg = Get-Content -LiteralPath $script:RegPath -Raw | ConvertFrom-Json
    }

    It 'registry.json parses' {
        { Get-Content -LiteralPath $script:RegPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'declares the Diagrams domain' {
        $script:reg.domains | Should -Contain 'Diagrams'
    }

    It 'catalogues Mermaid, D2, Graphviz and Kroki under Diagrams' {
        $diagRefs = @($script:reg.references | Where-Object domain -eq 'Diagrams')
        $refs = $diagRefs.ref -join ' '
        $refs | Should -Match 'mermaid-js/mermaid'
        $refs | Should -Match 'terrastruct/d2'
        $refs | Should -Match 'graphviz\.org'
        $refs | Should -Match 'kroki\.io'
    }

    It 'catalogues Graphify (not built, only referenced) with a sanitization note' {
        $g = @($script:reg.references | Where-Object { $_.ref -match 'Graphify-Labs/graphify' })
        $g | Should -Not -BeNullOrEmpty
        $g[0].note | Should -Match '(?i)sanitiz'
    }
}
