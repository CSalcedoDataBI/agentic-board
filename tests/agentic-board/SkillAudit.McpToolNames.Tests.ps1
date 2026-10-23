#Requires -Modules Pester
<#  Pester tests for the mcp-tool-name check of Invoke-SkillAudit.ps1 and for Get-McpServerNames.ps1.
    Everything runs on fixtures: the audit gets its MCP prefixes through -McpServers, and the
    discovery script reads a fixture home (-UserHome), never the live machine's config. #>

BeforeAll {
    $script:Audit    = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Invoke-SkillAudit.ps1'  | Resolve-Path
    $script:Discover = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Get-McpServerNames.ps1' | Resolve-Path
    $script:Root     = Join-Path ([System.IO.Path]::GetTempPath()) ("skillaudit-mcp-" + [guid]::NewGuid().ToString('N'))

    function New-Skill {
        param([string]$RelDir, [string]$Name, [string]$Body, [string]$Reference)
        $dir = Join-Path $script:Root $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        @("---","name: $Name",
          "description: Connects to a semantic model. Use when the user opens a model. Not for reports - see report-helper.",
          "---","",$Body) -join "`n" | Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8
        if ($Reference) {
            New-Item -ItemType Directory -Path (Join-Path $dir 'references') -Force | Out-Null
            $Reference | Set-Content -LiteralPath (Join-Path $dir 'references/ops.md') -Encoding utf8
        }
    }
    function Write-Json {
        param([string]$Path, $Value)
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    # bare: hardcodes the bare server, which this "machine" only has through a plugin.
    New-Skill '.claude/skills/proj/bare' 'bare' 'Call `mcp__powerbi-modeling-mcp__connection_operations` first.'
    # plugged: hardcodes the plugin prefix, but the server is configured directly here.
    New-Skill '.claude/skills/proj/plugged' 'plugged' 'Run `mcp__plugin_other-pack_codegraph__codegraph_search`.'
    # fine: references only names that exist, plus a placeholder pattern that is not a real name.
    New-Skill '.claude/skills/proj/fine' 'fine' 'Use `mcp__codegraph__codegraph_node`; plugin tools look like mcp__plugin_<plugin>_<server>__<tool>.'
    # absent: a server not installed anywhere says nothing.
    New-Skill '.claude/skills/proj/absent' 'absent' 'Try `mcp__never-installed__do_thing`.'
    # inref: the wrong name sits in references/, not in SKILL.md.
    New-Skill '.claude/skills/proj/inref' 'inref' 'See the references.' 'Wildcard: mcp__powerbi-modeling-mcp__*'

    $script:Servers = @('codegraph', 'plugin_fabric-skills_powerbi-modeling-mcp')
    $script:Res = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'me/proj' -McpServers $script:Servers
    function Get-McpFinding { param([string]$Skill) @($script:Res.findings | Where-Object { $_.skill -eq $Skill -and $_.type -eq 'mcp-tool-name' }) }
}

AfterAll {
    if ($script:Root -and (Test-Path $script:Root)) { Remove-Item $script:Root -Recurse -Force }
}

Describe 'Invoke-SkillAudit mcp-tool-name' {
    It 'flags a bare server name that is only installed through a plugin, with the working name' {
        $f = Get-McpFinding 'bare'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'med'
        $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__connection_operations'))
        $f[0].detail | Should -Match ([regex]::Escape('the powerbi-modeling-mcp `connection_operations` tool'))
    }
    It 'flags a plugin prefix when the server is configured directly' {
        (Get-McpFinding 'plugged')[0].detail | Should -Match ([regex]::Escape('mcp__codegraph__codegraph_search'))
    }
    It 'does not flag names that exist, nor placeholder patterns' {
        (Get-McpFinding 'fine').Count | Should -Be 0
    }
    It 'stays silent about a server that is not installed under any prefix' {
        (Get-McpFinding 'absent').Count | Should -Be 0
    }
    It 'reads the references folder and handles a wildcard tool' {
        $f = Get-McpFinding 'inref'
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__*'))
    }
    It 'routes the finding like every other one' {
        (Get-McpFinding 'bare')[0].filing | Should -Be 'file'
        (Get-McpFinding 'bare')[0].ownerRepo | Should -Be 'me/proj'
    }
    It 'reports one finding for several copies of the same skill' {
        New-Skill '.claude/worktrees/wt/.claude/skills/proj/bare' 'bare' 'Call `mcp__powerbi-modeling-mcp__connection_operations` first.'
        try {
            $r = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'me/proj' -McpServers $script:Servers
            $f = @($r.findings | Where-Object { $_.skill -eq 'bare' -and $_.type -eq 'mcp-tool-name' })
            $f.Count | Should -Be 1
            $f[0].copies | Should -Be 2
        } finally {
            Remove-Item (Join-Path $script:Root '.claude/worktrees') -Recurse -Force
        }
    }
    It 'skips the check when no MCP server is known' {
        $r = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'me/proj' -McpServers @()
        @($r.findings | Where-Object type -eq 'mcp-tool-name').Count | Should -Be 0
    }
}

Describe 'Get-McpServerNames' {
    BeforeAll {
        $script:Home2 = Join-Path $script:Root 'home'
        $script:Repo2 = Join-Path $script:Root 'repo'
        New-Item -ItemType Directory -Path $script:Repo2 -Force | Out-Null
        $repoKey = ([System.IO.Path]::GetFullPath($script:Repo2) -replace '\\','/')
        Write-Json (Join-Path $script:Home2 '.claude.json') ([ordered]@{
            mcpServers = @{ codegraph = @{ command = 'codegraph' } }
            projects   = @{ $repoKey = @{ mcpServers = @{ 'local-one' = @{ command = 'x' } } }; 'C:/elsewhere' = @{ mcpServers = @{ 'not-here' = @{} } } }
        })
        Write-Json (Join-Path $script:Repo2 '.mcp.json') @{ mcpServers = @{ 'proj-one' = @{ command = 'y' } } }
        $pa = Join-Path $script:Home2 'plugins/a'; $pb = Join-Path $script:Home2 'plugins/b'; $pc = Join-Path $script:Home2 'plugins/c'
        Write-Json (Join-Path $pa '.mcp.json') @{ 'powerbi-modeling-mcp' = @{ command = 'z' } }                 # flat map
        Write-Json (Join-Path $pb '.claude-plugin/plugin.json') @{ name = 'pack-b'; mcpServers = './servers.json' }
        Write-Json (Join-Path $pb 'servers.json') @{ mcpServers = @{ 'from-file' = @{} } }
        Write-Json (Join-Path $pc '.mcp.json') @{ mcpServers = @{ 'disabled-one' = @{} } }
        Write-Json (Join-Path $script:Home2 '.claude/plugins/installed_plugins.json') @{ version = 2; plugins = @{
            'fabric-skills@m' = @(@{ scope = 'user'; installPath = $pa; lastUpdated = '2026-01-01' })
            'pack-b@m'        = @(@{ scope = 'user'; installPath = $pb; lastUpdated = '2026-01-01' })
            'pack-c@m'        = @(@{ scope = 'user'; installPath = $pc; lastUpdated = '2026-01-01' })
        } }
        Write-Json (Join-Path $script:Home2 '.claude/settings.json') @{ enabledPlugins = @{ 'pack-c@m' = $false } }
        $script:Names = @(& $script:Discover -Root $script:Repo2 -UserHome $script:Home2)
    }
    It 'lists direct servers by their bare name (user, local project entry, .mcp.json)' {
        $script:Names.prefix | Should -Contain 'codegraph'
        $script:Names.prefix | Should -Contain 'local-one'
        $script:Names.prefix | Should -Contain 'proj-one'
        $script:Names.prefix | Should -Not -Contain 'not-here'
    }
    It 'lists plugin servers with the plugin prefix, from .mcp.json and from plugin.json' {
        $script:Names.prefix | Should -Contain 'plugin_fabric-skills_powerbi-modeling-mcp'
        $script:Names.prefix | Should -Contain 'plugin_pack-b_from-file'
    }
    It 'never reads the other keys of ~/.claude.json or a project entry as servers' {
        Write-Json (Join-Path $script:Home2 '.claude.json') @{ numStartups = 3; projects = @{ 'C:/x' = @{ allowedTools = @() } } }
        try {
            $n = @(& $script:Discover -Root 'C:/x' -UserHome $script:Home2).prefix
            $n | Should -Not -Contain 'numStartups'
            $n | Should -Not -Contain 'projects'
            $n | Should -Not -Contain 'allowedTools'
        } finally {
            Write-Json (Join-Path $script:Home2 '.claude.json') @{ mcpServers = @{ codegraph = @{} } }
        }
    }
    It 'leaves out disabled plugins' {
        $script:Names.prefix | Should -Not -Contain 'plugin_pack-c_disabled-one'
    }
    It 'returns nothing on an empty home' {
        $empty = Join-Path $script:Root 'empty'; New-Item -ItemType Directory -Path $empty -Force | Out-Null
        @(& $script:Discover -Root $empty -UserHome $empty).Count | Should -Be 0
    }
}
