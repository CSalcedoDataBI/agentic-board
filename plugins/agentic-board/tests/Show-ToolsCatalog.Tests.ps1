#Requires -Modules Pester
<#  Tests for Show-ToolsCatalog.ps1 (#386) — the browse + research view over the catalog resolver.
    browse: every tool listed, grouped by domain, each row carrying its URL and installed-state.
    research <id>: surfaces one tool's exact reference (URL + note) before install.
#>

BeforeAll {
    $script:Show = Join-Path $PSScriptRoot '..' 'scripts' 'Show-ToolsCatalog.ps1'

    $script:Root = Join-Path $TestDrive 'proj'
    $regDir = Join-Path $script:Root 'knowledge'; New-Item -ItemType Directory -Force -Path $regDir | Out-Null
    @{
        version=1; project='proj'; domains=@('PowerBI','Vega')
        references=@(
            @{ id='kn_001'; domain='PowerBI'; type='repo'; title='skills-for-fabric marketplace'; ref='https://github.com/microsoft/skills-for-fabric'; note='seed of the BI toolkit'; added='2026-07-22' }
            @{ id='kn_002'; domain='Vega';    type='url';  title='Vega docs'; ref='https://vega.github.io/'; note='charts grammar'; added='2026-07-22' }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $regDir 'registry.json') -Encoding utf8

    $script:CatalogDir = Join-Path $TestDrive 'toolkits'; New-Item -ItemType Directory -Force -Path $script:CatalogDir | Out-Null
    ,@( @{ name='skills-for-fabric'; owner='Microsoft'; repo='microsoft/skills-for-fabric'; kind='plugin'; detect='fabric-collection'; path=$null; homepage='https://github.com/microsoft/skills-for-fabric'; install='claude plugin marketplace add microsoft/skills-for-fabric'; purpose='Fabric/PBI skills + MCP.' } ) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'bi.json') -Encoding utf8
    ,@( @{ name='skill-creator'; owner='Anthropic'; repo='anthropics/skills'; kind='skill-clone'; detect=$null; path='skill-creator'; homepage='https://github.com/anthropics/skills'; install=$null; purpose='Author and test skills.' } ) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'quality.json') -Encoding utf8

    $script:Common = @{ Root=$script:Root; CatalogDir=$script:CatalogDir; InstalledNames=@('skill-creator'); InstalledPlugins=@() }
}

Describe 'Show-ToolsCatalog — browse' {
    BeforeAll { $script:Browse = (& $script:Show @script:Common) -join "`n" }

    It 'groups tools under their domain headers' {
        $script:Browse | Should -Match 'PowerBI'
        $script:Browse | Should -Match 'Vega'
    }
    It 'shows every tool URL' {
        $script:Browse | Should -Match ([regex]::Escape('github.com/microsoft/skills-for-fabric'))
        $script:Browse | Should -Match ([regex]::Escape('vega.github.io'))
        $script:Browse | Should -Match ([regex]::Escape('github.com/anthropics/skills'))
    }
    It 'marks an installed tool as installed and a bare reference as reference' {
        ($script:Browse -split "`n" | Where-Object { $_ -match 'skill-creator' }) -join '' | Should -Match 'installed'
        ($script:Browse -split "`n" | Where-Object { $_ -match 'kn_002' })       -join '' | Should -Match 'reference'
    }
}

Describe 'Show-ToolsCatalog — research <id>' {
    It 'surfaces the exact URL and note for one tool' {
        $r = (& $script:Show @script:Common -Id 'kn_002') -join "`n"
        $r | Should -Match ([regex]::Escape('vega.github.io'))
        $r | Should -Match 'charts grammar'
    }
    It 'resolves by name too and shows the install method for an installable' {
        $r = (& $script:Show @script:Common -Id 'skills-for-fabric') -join "`n"
        $r | Should -Match 'marketplace'
    }
    It 'reports a clear message for an unknown id' {
        $r = (& $script:Show @script:Common -Id 'does-not-exist') -join "`n"
        $r | Should -Match 'not found'
    }
}
