#Requires -Modules Pester
<#  Tests for Install-ToolFromCatalog.ps1 (#387) — install ONE referenced tool by id.

    skill-clone → delegates to the injected installer (real default: Install-SkillFromRepo.ps1).
    plugin      → surfaces its own install command (all-or-nothing, never auto-run).
    reference / already-installed / unknown id → clear no-op messages.
    Network is never touched: the installer is injected via -InstallSkillWith and records its calls.
#>

BeforeAll {
    $script:Install = Join-Path $PSScriptRoot '..' 'scripts' 'Install-ToolFromCatalog.ps1'

    # --- fixtures: a plugin, a skill-clone, and a bare reference
    $script:Root = Join-Path $TestDrive 'proj'
    $regDir = Join-Path $script:Root 'knowledge'; New-Item -ItemType Directory -Force -Path $regDir | Out-Null
    @{
        version=1; project='proj'; domains=@('Vega')
        references=@( @{ id='kn_002'; domain='Vega'; type='url'; title='Vega docs'; ref='https://vega.github.io/'; note='charts'; added='2026-07-22' } )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $regDir 'registry.json') -Encoding utf8

    $script:CatalogDir = Join-Path $TestDrive 'toolkits'; New-Item -ItemType Directory -Force -Path $script:CatalogDir | Out-Null
    ,@( @{ name='skills-for-fabric'; owner='Microsoft'; repo='microsoft/skills-for-fabric'; kind='plugin'; detect='fabric-collection'; path=$null; homepage='https://github.com/microsoft/skills-for-fabric'; install='claude plugin marketplace add microsoft/skills-for-fabric'; purpose='Fabric skills.' } ) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'bi.json') -Encoding utf8
    ,@( @{ name='skill-creator'; owner='Anthropic'; repo='anthropics/skills'; kind='skill-clone'; detect=$null; path='skill-creator'; homepage='https://github.com/anthropics/skills'; license='Anthropic'; install=$null; purpose='Author skills.' } ) |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:CatalogDir 'quality.json') -Encoding utf8

    # --- injected installer stub: records its args, never clones
    $script:StubLog = Join-Path $TestDrive 'stub-calls.txt'
    $script:Stub    = Join-Path $TestDrive 'Stub-Installer.ps1'
    Set-Content -LiteralPath $script:Stub -Encoding utf8 -Value @'
param([string]$Repo,[string]$Path,[string]$Name,[string]$Owner="",[string]$License="",[string]$Dest,[switch]$Force)
"$Repo|$Path|$Name|$Owner|$License" | Add-Content -LiteralPath $env:ABIOS_STUB_LOG
[pscustomobject]@{ name=$Name; installed=$true; source="$Repo/$Path" }
'@
    $env:ABIOS_STUB_LOG = $script:StubLog

    $script:Base = @{ Root=$script:Root; CatalogDir=$script:CatalogDir; InstallSkillWith=$script:Stub; InstalledPlugins=@() }
}

Describe 'Install-ToolFromCatalog — install one (#387)' {
    AfterEach { if (Test-Path $script:StubLog) { Remove-Item $script:StubLog -Force } }

    It 'installs a skill-clone by delegating to the installer with repo/path/name' {
        $out = (& $script:Install -Id 'skill-creator' @script:Base -InstalledNames @()) -join "`n"
        (Get-Content -LiteralPath $script:StubLog -Raw) | Should -Match ([regex]::Escape('anthropics/skills|skill-creator|skill-creator'))
        $out | Should -Match 'skill-creator'
    }

    It '-DryRun does NOT call the installer' {
        $out = (& $script:Install -Id 'skill-creator' @script:Base -InstalledNames @() -DryRun) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'WOULD'
    }

    It 'surfaces the install command for a plugin instead of running it' {
        $out = (& $script:Install -Id 'skills-for-fabric' @script:Base -InstalledNames @()) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'marketplace'
        $out | Should -Match 'plugin'
    }

    It 'skips a tool that is already installed' {
        $out = (& $script:Install -Id 'skill-creator' @script:Base -InstalledNames @('skill-creator')) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'already installed'
    }

    It 'refuses a bare reference (not installable)' {
        $out = (& $script:Install -Id 'kn_002' @script:Base -InstalledNames @()) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'not installable'
    }

    It 'reports a clear message for an unknown id' {
        $out = (& $script:Install -Id 'nope' @script:Base -InstalledNames @()) -join "`n"
        $out | Should -Match 'not found'
    }
}

Describe 'Install-ToolFromCatalog — install --all (#388)' {
    AfterEach { if (Test-Path $script:StubLog) { Remove-Item $script:StubLog -Force } }

    It '-All -DryRun lists skill-clones and plugins separately, installing nothing' {
        $out = (& $script:Install -All @script:Base -InstalledNames @() -InstalledMcpServers @() -DryRun) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match '1 skill-clone\(s\) to install, 1 plugin\(s\)'
        $out | Should -Match 'skill-creator \(skill-clone anthropics/skills'   # skill listed in the plan
        $out | Should -Match 'marketplace'                                     # fabric plugin surfaced
    }

    It '-All without -Yes is a safe preview (no install)' {
        $out = (& $script:Install -All @script:Base -InstalledNames @() -InstalledMcpServers @()) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match '-Yes'
    }

    It '-All -Yes installs the skill-clones and surfaces the plugins' {
        $out = (& $script:Install -All @script:Base -InstalledNames @() -InstalledMcpServers @() -Yes) -join "`n"
        (Get-Content -LiteralPath $script:StubLog -Raw) | Should -Match ([regex]::Escape('anthropics/skills|skill-creator|skill-creator'))
        (Get-Content -LiteralPath $script:StubLog -Raw) | Should -Not -Match 'skills-for-fabric'  # plugin not auto-run
        $out | Should -Match 'installed 1 skill-clone'
    }

    It '-All reports nothing to do when all installables are present' {
        $b = $script:Base.Clone(); $b.InstalledPlugins = @('fabric-collection')
        $out = (& $script:Install -All @b -InstalledNames @('skill-creator') -InstalledMcpServers @() -Yes) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'nothing to install'
    }
}

Describe 'Install-ToolFromCatalog — mcp kind (#416)' {
    BeforeAll {
        $script:McpCatalogDir = Join-Path $TestDrive 'mcp-toolkits'
        New-Item -ItemType Directory -Force -Path $script:McpCatalogDir | Out-Null
        ,@( @{ name='deepwiki-mcp'; owner='Cognition'; repo='cognitionai/deepwiki'; kind='mcp'; detect='deepwiki'; path=$null; homepage='https://deepwiki.com'; license='see repo'; install='claude mcp add --transport sse deepwiki https://mcp.deepwiki.com/sse'; purpose='AI wiki.' } ) |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:McpCatalogDir 'mcp.json') -Encoding utf8

        $script:McpRoot = Join-Path $TestDrive 'mcp-proj'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:McpRoot 'knowledge') | Out-Null
        @{ version=1; project='test'; domains=@(); references=@() } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:McpRoot 'knowledge' 'registry.json') -Encoding utf8

        $script:McpBase = @{
            Root              = $script:McpRoot
            CatalogDir        = $script:McpCatalogDir
            InstallSkillWith  = $script:Stub
            InstalledPlugins  = @()
            InstalledMcpServers = @()
        }
    }

    AfterEach { if (Test-Path $script:StubLog) { Remove-Item $script:StubLog -Force } }

    It 'surfaces the claude mcp add command for an mcp entry' {
        $out = (& $script:Install -Id 'deepwiki-mcp' @script:McpBase -InstalledNames @()) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'MCP server'
        $out | Should -Match 'claude mcp add'
        $out | Should -Match 'deepwiki'
    }

    It 'skips an mcp server that is already installed' {
        $b = $script:McpBase.Clone(); $b.InstalledMcpServers = @('deepwiki')
        $out = (& $script:Install -Id 'deepwiki-mcp' @b -InstalledNames @()) -join "`n"
        (Test-Path $script:StubLog) | Should -BeFalse
        $out | Should -Match 'already installed'
    }

    It '-All includes mcp servers in the surfaced count' {
        $out = (& $script:Install -All @script:McpBase -InstalledNames @() -Yes) -join "`n"
        $out | Should -Match 'MCP server'
    }
}
