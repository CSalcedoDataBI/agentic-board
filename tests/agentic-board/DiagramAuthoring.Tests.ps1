#Requires -Modules Pester
<#  Pester tests for the diagram-authoring skill (#376) and the Diagrams knowledge domain (#378).

    Asserts the skill exists as an INTERNAL support skill (never a typed command), and that the
    knowledge registry carries the Diagrams domain refs + the Graphify catalogue entry.
#>

BeforeAll {
    $script:PluginRoot = Join-Path $PSScriptRoot '..' | Resolve-Path
    $script:RepoRoot   = Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path
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
