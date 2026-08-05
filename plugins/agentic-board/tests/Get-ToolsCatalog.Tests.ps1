#Requires -Modules Pester
<#  Tests for Get-ToolsCatalog.ps1 (#385) — the unified referenced-tools catalog resolver.

    It merges the knowledge registry (references) with the toolkit presets (installers) into one
    item model, de-duplicated by URL, with installed-detection reusing the Get-SkillGaps rules
    (skill-clone by name, plugin by detect/name). Fixtures are built under TestDrive so nothing
    depends on the live registry or installed inventory.
#>

BeforeAll {
    $script:Resolver = Join-Path $PSScriptRoot '..' 'scripts' 'Get-ToolsCatalog.ps1'

    # --- fixture: a registry with one ref that OVERLAPS a preset (skills-for-fabric) and one that does not
    $script:Root = Join-Path $TestDrive 'proj'
    $regDir = Join-Path $script:Root 'knowledge'
    New-Item -ItemType Directory -Force -Path $regDir | Out-Null
    @{
        version    = 1
        project    = 'proj'
        domains    = @('PowerBI','Vega')
        references = @(
            @{ id='kn_001'; domain='PowerBI'; type='repo'; title='skills-for-fabric marketplace'; ref='https://github.com/microsoft/skills-for-fabric'; note='seed of the BI toolkit'; added='2026-07-22' }
            @{ id='kn_002'; domain='Vega';    type='url';  title='Vega docs';                    ref='https://vega.github.io/';                         note='charts grammar';     added='2026-07-22' }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $regDir 'registry.json') -Encoding utf8

    # --- fixture: two toolkit presets (one plugin, one skill-clone)
    $script:CatalogDir = Join-Path $TestDrive 'toolkits'
    New-Item -ItemType Directory -Force -Path $script:CatalogDir | Out-Null
    ,@(
        @{ name='skills-for-fabric'; owner='Microsoft'; repo='microsoft/skills-for-fabric'; kind='plugin'; detect='fabric-collection'; path=$null; homepage='https://github.com/microsoft/skills-for-fabric'; install='claude plugin marketplace add microsoft/skills-for-fabric'; purpose='Fabric/PBI skills + MCP.' }
    ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'bi.json') -Encoding utf8
    ,@(
        @{ name='skill-creator'; owner='Anthropic'; repo='anthropics/skills'; kind='skill-clone'; detect=$null; path='skill-creator'; homepage='https://github.com/anthropics/skills'; install=$null; purpose='Author and test skills.' }
    ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'quality.json') -Encoding utf8

    # skill-creator is "installed", the fabric plugin is not
    $script:Common = @{
        Root             = $script:Root
        CatalogDir       = $script:CatalogDir
        InstalledNames   = @('skill-creator')
        InstalledPlugins = @()
    }
    $script:Cat = & $script:Resolver @script:Common
}

Describe 'Get-ToolsCatalog — unified model' {
    It 'merges registry + presets and de-duplicates by URL' {
        # registry(2) ∪ presets(2), skills-for-fabric collapses to one → 3 items
        @($script:Cat.items).Count | Should -Be 3
    }

    It 'marks the overlapping tool as coming from BOTH sources and installable' {
        $f = $script:Cat.items | Where-Object { $_.id -eq 'skills-for-fabric' }
        $f | Should -Not -BeNullOrEmpty
        $f.source      | Should -Be 'both'
        $f.installable | Should -BeTrue
        $f.kind        | Should -Be 'plugin'
        $f.installed   | Should -BeFalse -Because 'the fabric plugin is not in InstalledPlugins'
        $f.installMethod | Should -Match 'marketplace'
    }

    It 'detects an installed skill-clone by name' {
        $s = $script:Cat.items | Where-Object { $_.id -eq 'skill-creator' }
        $s.installable | Should -BeTrue
        $s.kind        | Should -Be 'skill-clone'
        $s.installed   | Should -BeTrue
        $s.source      | Should -Be 'preset'
    }

    It 'keeps a registry-only reference as non-installable' {
        $v = $script:Cat.items | Where-Object { $_.id -eq 'kn_002' }
        $v.installable | Should -BeFalse
        $v.source      | Should -Be 'registry'
        $v.domain      | Should -Be 'Vega'
    }

    It 'reports a summary count' {
        $script:Cat.summary.total       | Should -Be 3
        $script:Cat.summary.installable | Should -Be 2
        $script:Cat.summary.installed   | Should -Be 1
    }
}

Describe 'Get-ToolsCatalog — filters and lookup' {
    It '-MissingOnly returns only installable tools that are not installed' {
        $missing = & $script:Resolver @script:Common -MissingOnly
        @($missing.items).Count | Should -Be 1
        $missing.items[0].id | Should -Be 'skills-for-fabric'
    }

    It '-Id resolves one item by id' {
        $one = & $script:Resolver @script:Common -Id 'kn_002'
        @($one.items).Count | Should -Be 1
        $one.items[0].domain | Should -Be 'Vega'
    }

    It '-Id resolves by name case-insensitively' {
        $one = & $script:Resolver @script:Common -Id 'SKILLS-FOR-FABRIC'
        @($one.items).Count | Should -Be 1
        $one.items[0].kind | Should -Be 'plugin'
    }

    It '-Json emits parseable JSON with the same items' {
        $json = & $script:Resolver @script:Common -Json
        $parsed = $json | ConvertFrom-Json
        @($parsed.items).Count | Should -Be 3
    }
}

Describe 'Get-ToolsCatalog — resilience' {
    It 'works with no registry (presets only)' {
        $empty = Join-Path $TestDrive 'noreg'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $cat = & $script:Resolver -Root $empty -CatalogDir $script:CatalogDir -InstalledNames @() -InstalledPlugins @()
        @($cat.items).Count | Should -Be 2
        ($cat.items | Where-Object installable).Count | Should -Be 2
    }

    It 'keeps two skills from the SAME monorepo as distinct items (no URL-collapse)' {
        # regression: skill-improver + second-opinion both live in trailofbits/skills (same homepage)
        $mono = Join-Path $TestDrive 'mono'; New-Item -ItemType Directory -Force -Path $mono | Out-Null
        ,@(
            @{ name='skill-improver'; repo='trailofbits/skills'; kind='skill-clone'; path='skill-improver'; homepage='https://github.com/trailofbits/skills'; install=$null; purpose='improve' }
            @{ name='second-opinion'; repo='trailofbits/skills'; kind='skill-clone'; path='second-opinion'; homepage='https://github.com/trailofbits/skills'; install=$null; purpose='review' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $mono 'q.json') -Encoding utf8
        $noreg = Join-Path $TestDrive 'mono-root'; New-Item -ItemType Directory -Force -Path $noreg | Out-Null
        $cat = & $script:Resolver -Root $noreg -CatalogDir $mono -InstalledNames @() -InstalledPlugins @()
        @($cat.items).Count | Should -Be 2
        ($cat.items.id | Sort-Object) | Should -Be @('second-opinion','skill-improver')
    }
}

Describe 'Get-ToolsCatalog — mcp kind (#416)' {
    BeforeAll {
        $script:McpDir = Join-Path $TestDrive 'mcp-toolkits'
        New-Item -ItemType Directory -Force -Path $script:McpDir | Out-Null
        ,@(
            @{ name='deepwiki-mcp'; owner='Cognition'; repo='cognitionai/deepwiki'; kind='mcp'; detect='deepwiki'; path=$null; homepage='https://deepwiki.com'; license='see repo'; install='claude mcp add --transport sse deepwiki https://mcp.deepwiki.com/sse'; purpose='AI wiki for public GitHub repos.' }
        ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:McpDir 'mcp.json') -Encoding utf8

        $script:McpRoot = Join-Path $TestDrive 'mcp-proj'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:McpRoot 'knowledge') | Out-Null
        @{ version=1; project='test'; domains=@(); references=@() } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:McpRoot 'knowledge' 'registry.json') -Encoding utf8
    }

    It 'includes mcp entries in the catalog as installable' {
        $cat = & $script:Resolver -Root $script:McpRoot -CatalogDir $script:McpDir `
            -InstalledNames @() -InstalledPlugins @() -InstalledMcpServers @()
        $entry = $cat.items | Where-Object { $_.id -eq 'deepwiki-mcp' }
        $entry            | Should -Not -BeNullOrEmpty
        $entry.kind       | Should -Be 'mcp'
        $entry.installable| Should -BeTrue
        $entry.installed  | Should -BeFalse
        $entry.installMethod | Should -Match 'claude mcp add'
    }

    It 'detects a mcp server as installed when its detect name is in InstalledMcpServers' {
        $cat = & $script:Resolver -Root $script:McpRoot -CatalogDir $script:McpDir `
            -InstalledNames @() -InstalledPlugins @() -InstalledMcpServers @('deepwiki')
        $entry = $cat.items | Where-Object { $_.id -eq 'deepwiki-mcp' }
        $entry.installed | Should -BeTrue
    }

    It 'excludes a detected mcp server from MissingOnly results' {
        $missing = & $script:Resolver -Root $script:McpRoot -CatalogDir $script:McpDir `
            -InstalledNames @() -InstalledPlugins @() -InstalledMcpServers @('deepwiki') -MissingOnly
        $missing.items | Where-Object { $_.id -eq 'deepwiki-mcp' } | Should -BeNullOrEmpty
    }

    It 'mcp detection is case-insensitive' {
        $cat = & $script:Resolver -Root $script:McpRoot -CatalogDir $script:McpDir `
            -InstalledNames @() -InstalledPlugins @() -InstalledMcpServers @('DEEPWIKI')
        $entry = $cat.items | Where-Object { $_.id -eq 'deepwiki-mcp' }
        $entry.installed | Should -BeTrue
    }
}
