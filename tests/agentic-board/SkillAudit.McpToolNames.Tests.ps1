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

    # selfref: a plugin's skill naming its OWN plugin prefix, from a tree where that plugin is not enabled.
    # Its second, foreign prefix is the control that proves the skill was audited at all.
    New-Skill 'plugins/pack-z/skills/selfref' 'selfref' 'Run `mcp__plugin_pack-z_codegraph__codegraph_search`, then `mcp__plugin_pack-y_codegraph__codegraph_node`.'
    # both: documents both install forms, one of which works here.
    New-Skill '.claude/skills/proj/both' 'both' 'Use `mcp__powerbi-modeling-mcp__model_operations`, or `mcp__plugin_fabric-skills_powerbi-modeling-mcp__model_operations` when the plugin brings it.'

    # multi: three tools under one hardcoded prefix - one root cause, one finding.
    New-Skill '.claude/skills/proj/multi' 'multi' 'Use `mcp__powerbi-modeling-mcp__table_operations`, `mcp__powerbi-modeling-mcp__column_operations` and `mcp__powerbi-modeling-mcp__measure_operations`.'
    # covers: hardcodes the bare form but also allows the working prefix in another form.
    New-Skill '.claude/skills/proj/covers' 'covers' 'allowed-tools: mcp__plugin_fabric-skills_powerbi-modeling-mcp. Then call `mcp__powerbi-modeling-mcp__dax_query_operations`.'
    # beside: the wrong name sits in a markdown file next to SKILL.md.
    New-Skill '.claude/skills/proj/beside' 'beside' 'See reference.md.'
    'Call `mcp__powerbi-modeling-mcp__partition_operations`.' | Set-Content -LiteralPath (Join-Path $script:Root '.claude/skills/proj/beside/reference.md') -Encoding utf8
    # allowed: the bare mcp__<server> form allowed-tools uses for all of a server's tools.
    New-Skill '.claude/skills/proj/allowed' 'allowed' "Frontmatter would say allowed-tools: mcp__powerbi-modeling-mcp, Read."

    # Runs a COPY of the scripts whose discovery is replaced by $Stub, without -McpServers unless given:
    # the audit's own discovery path, on known data, never this machine's config.
    function Invoke-StubbedAudit {
        param([string]$Stub, [hashtable]$Extra = @{})
        $copy = Join-Path ([System.IO.Path]::GetTempPath()) ("skillaudit-scripts-" + [guid]::NewGuid().ToString('N'))
        Copy-Item -Path (Split-Path $script:Audit -Parent) -Destination $copy -Recurse
        try {
            $Stub | Set-Content -LiteralPath (Join-Path $copy 'Get-McpServerNames.ps1') -Encoding utf8BOM
            $w = $null
            $r = & (Join-Path $copy 'Invoke-SkillAudit.ps1') -Root $script:Root -Scope project -CurrentRepo 'me/proj' @Extra -WarningVariable w -WarningAction SilentlyContinue
            [pscustomobject]@{ result = $r; warnings = ($w -join ' ') }
        } finally {
            Remove-Item $copy -Recurse -Force
        }
    }
    $script:StubPluginOnly = "[pscustomobject]@{ prefix = 'plugin_fabric-skills_powerbi-modeling-mcp'; server = 'powerbi-modeling-mcp'; plugin = 'fabric-skills' }"

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
    It 'does not flag a plugin skill that names its own plugin prefix' {
        $f = Get-McpFinding 'selfref'
        $f.Count | Should -Be 1                     # only the foreign pack-y prefix
        $f[0].detail | Should -Match 'plugin_pack-y_codegraph'
        $f[0].detail | Should -Not -Match 'plugin_pack-z_'     # the own prefix never leaks into it
    }
    It 'does not flag a skill that already gives the working name too' {
        (Get-McpFinding 'both').Count | Should -Be 0
    }
    It 'does not flag a skill that gives the working prefix in another form' {
        (Get-McpFinding 'covers').Count | Should -Be 0
    }
    It 'reports one finding per hardcoded prefix, listing every name under it' {
        $f = Get-McpFinding 'multi'
        $f.Count | Should -Be 1
        foreach ($t in 'table_operations', 'column_operations', 'measure_operations') {
            $f[0].detail | Should -Match ([regex]::Escape("mcp__powerbi-modeling-mcp__$t"))
        }
        $f[0].detail | Should -Match '3 names under one prefix'
        $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__…'))
    }
    It 'names each working prefix once even if it is listed twice' {
        $r = & $script:Audit -Root $script:Root -Scope project -CurrentRepo 'me/proj' -McpServers ($script:Servers + 'plugin_fabric-skills_powerbi-modeling-mcp')
        $d = @($r.findings | Where-Object { $_.skill -eq 'bare' -and $_.type -eq 'mcp-tool-name' })[0].detail
        ([regex]::Matches($d, [regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__connection_operations'))).Count | Should -Be 1
    }
    It 'skips the check, and keeps the rest of the audit, when discovery fails' {
        $x = Invoke-StubbedAudit "throw 'discovery broke'"
        @($x.result.findings | Where-Object type -eq 'mcp-tool-name').Count | Should -Be 0
        $x.result.summary.skillsAudited | Should -BeGreaterThan 0
        $x.warnings | Should -Match 'discovery failed'
        $x.result.summary.mcpCheck | Should -Be 'discovery-failed'
    }
    It 'uses the discovered records when -McpServers is omitted' {
        $x = Invoke-StubbedAudit $script:StubPluginOnly
        $f = @($x.result.findings | Where-Object { $_.skill -eq 'bare' -and $_.type -eq 'mcp-tool-name' })
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__connection_operations'))
    }
    It 'takes the server name from the record when the plugin name holds an underscore' {
        New-Skill '.claude/skills/proj/gh' 'gh' 'Call `mcp__github__create_issue`.'
        try {
            $x = Invoke-StubbedAudit "[pscustomobject]@{ prefix = 'plugin_acme_tools_github'; server = 'github'; plugin = 'acme_tools' }"
            $f = @($x.result.findings | Where-Object { $_.skill -eq 'gh' -and $_.type -eq 'mcp-tool-name' })
            $f.Count | Should -Be 1
            $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_acme_tools_github__create_issue'))
        } finally {
            Remove-Item (Join-Path $script:Root '.claude/skills/proj/gh') -Recurse -Force
        }
    }
    It 'flags the bare server-only form that allowed-tools uses' {
        $f = Get-McpFinding 'allowed'
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match ([regex]::Escape('`mcp__plugin_fabric-skills_powerbi-modeling-mcp`'))
        $f[0].detail | Should -Match 'the powerbi-modeling-mcp tools'
    }
    It 'never puts a local path in a finding detail (they may be filed publicly)' {
        foreach ($f in @($script:Res.findings | Where-Object type -eq 'mcp-tool-name')) {
            $f.detail | Should -Not -Match ([regex]::Escape($script:Root))
            $f.detail | Should -Not -Match ([regex]::Escape(($script:Root -replace '\\','/')))
            $f.detail | Should -Not -Match 'references/|SKILL\.md'
        }
    }
    It 'stays silent about a server that is not installed under any prefix' {
        (Get-McpFinding 'absent').Count | Should -Be 0
    }
    It 'reads the references folder and handles a wildcard tool' {
        $f = Get-McpFinding 'inref'
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match ([regex]::Escape('mcp__plugin_fabric-skills_powerbi-modeling-mcp__*'))
    }
    It 'reads markdown files beside SKILL.md and says the check ran' {
        (Get-McpFinding 'beside').Count | Should -Be 1
        $script:Res.summary.mcpCheck | Should -Be 'ran'
    }
    It 'tells the owner how to fix a literal allowed-tools list' {
        (Get-McpFinding 'allowed')[0].detail | Should -Match 'list both install forms'
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
    It 'skips the check when -McpServers is an explicit empty list, without falling back to discovery' {
        # The stub WOULD produce findings, so a fallback to discovery fails this test.
        $x = Invoke-StubbedAudit $script:StubPluginOnly @{ McpServers = @() }
        @($x.result.findings | Where-Object type -eq 'mcp-tool-name').Count | Should -Be 0
        $x.result.summary.skillsAudited | Should -BeGreaterThan 0   # the audit did run
        $x.result.summary.mcpCheck | Should -Be 'no-servers'
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
            projects   = @{
                $repoKey = @{ mcpServers = @{ 'local-one' = @{ command = 'x' }; 'switched-off' = @{} }
                              enabledMcpjsonServers = @('proj-one'); disabledMcpServers = @('switched-off', 'plugin:pack-b:from-file') }
                'C:/elsewhere' = @{ mcpServers = @{ 'not-here' = @{} } }
            }
        })
        Write-Json (Join-Path $script:Repo2 '.mcp.json') @{ mcpServers = @{ 'proj-one' = @{ command = 'y' }; 'unapproved' = @{} } }
        $pa = Join-Path $script:Home2 'plugins/a'; $pb = Join-Path $script:Home2 'plugins/b'; $pc = Join-Path $script:Home2 'plugins/c'
        Write-Json (Join-Path $pa '.mcp.json') @{ 'powerbi-modeling-mcp' = @{ command = 'z' } }                 # flat map
        Write-Json (Join-Path $pb '.claude-plugin/plugin.json') @{ name = 'pack-b'; mcpServers = './servers.json' }
        Write-Json (Join-Path $pb 'servers.json') @{ mcpServers = @{ 'from-file' = @{}; 'second' = @{} } }
        Write-Json (Join-Path $pc '.mcp.json') @{ mcpServers = @{ 'disabled-one' = @{} } }
        $pw = Join-Path $script:Home2 'plugins/w'; Write-Json (Join-Path $pw '.mcp.json') @{ mcpServers = @{ 'wrapped-one' = @{} } }
        $pu = Join-Path $script:Home2 'plugins/u'; Write-Json (Join-Path $pu '.mcp.json') @{ 'unnamed-one' = @{} }
        Write-Json (Join-Path $script:Home2 '.claude/plugins/installed_plugins.json') @{ version = 2; plugins = @{
            'fabric-skills@m' = @(@{ scope = 'user'; installPath = $pa; lastUpdated = '2026-01-01' })
            'pack-b@m'        = @(@{ scope = 'user'; installPath = $pb; lastUpdated = '2026-01-01' })
            'pack-c@m'        = @(@{ scope = 'user'; installPath = $pc; lastUpdated = '2026-01-01' })
            'pack-w@m'        = @(@{ scope = 'user'; installPath = $pw; lastUpdated = '2026-01-01' })
            'pack-u@m'        = @(@{ scope = 'user'; installPath = $pu; lastUpdated = '2026-01-01' })   # named in no enabledPlugins
        } }
        Write-Json (Join-Path $script:Home2 '.claude/settings.json') @{ enabledPlugins = @{ 'fabric-skills@m' = $true; 'pack-b@m' = $true; 'pack-w@m' = $true; 'pack-c@m' = $false } }
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
        $script:Names.prefix | Should -Contain 'plugin_pack-b_second'
    }
    It 'leaves out servers switched off in the project, direct and plugin ones' {
        $script:Names.prefix | Should -Not -Contain 'switched-off'
        $script:Names.prefix | Should -Not -Contain 'plugin_pack-b_from-file'
    }
    It 'lets the most specific settings level decide enableAllProjectMcpServers' {
        $r4 = Join-Path $script:Root 'repo4'
        Write-Json (Join-Path $r4 '.mcp.json') @{ mcpServers = @{ 'any-one' = @{} } }
        Write-Json (Join-Path $r4 '.claude/settings.json') @{ enableAllProjectMcpServers = $true }
        @(& $script:Discover -Root $r4 -UserHome $script:Home2).prefix | Should -Contain 'any-one'
        Write-Json (Join-Path $r4 '.claude/settings.local.json') @{ enableAllProjectMcpServers = $false }
        @(& $script:Discover -Root $r4 -UserHome $script:Home2).prefix | Should -Not -Contain 'any-one'
    }
    It 'leaves out a project .mcp.json server that was never approved' {
        $script:Names.prefix | Should -Not -Contain 'unapproved'
    }
    It 'still reads ~/.claude.json when it holds keys that differ only in case' {
        $file = Join-Path $script:Home2 '.claude.json'
        $saved = Get-Content -LiteralPath $file -Raw
        try {
            '{"mcpServers":{"codegraph":{}},"projects":{"c:/dup":{},"C:/dup":{}}}' | Set-Content -LiteralPath $file -Encoding utf8
            @(& $script:Discover -Root $script:Repo2 -UserHome $script:Home2).prefix | Should -Contain 'codegraph'
        } finally {
            $saved | Set-Content -LiteralPath $file -Encoding utf8 -NoNewline
        }
    }
    It 'never reads the other keys of ~/.claude.json or a project entry as servers' {
        $file = Join-Path $script:Home2 '.claude.json'
        $saved = Get-Content -LiteralPath $file -Raw
        $xRoot = Join-Path $script:Root 'xroot'; New-Item -ItemType Directory -Path $xRoot -Force | Out-Null
        Write-Json $file @{ numStartups = 3; mcpServers = @{ 'real-one' = @{} }; projects = @{ ($xRoot -replace '\\','/') = @{ allowedTools = @() } } }
        try {
            $n = @(& $script:Discover -Root $xRoot -UserHome $script:Home2).prefix
            $n | Should -Not -Contain 'numStartups'
            $n | Should -Not -Contain 'projects'
            $n | Should -Not -Contain 'allowedTools'
            $n | Should -Contain 'real-one'                  # the file WAS read
        } finally {
            $saved | Set-Content -LiteralPath $file -Encoding utf8 -NoNewline
        }
    }
    It 'leaves out disabled plugins' {
        $script:Names.prefix | Should -Contain 'plugin_pack-w_wrapped-one'     # the same wrapped shape IS read when enabled
        @($script:Names.prefix | Where-Object { $_ -like 'plugin_pack-c_*' }).Count | Should -Be 0
    }
    It 'leaves out an installed plugin that no enabledPlugins sets to true' {
        @($script:Names.prefix | Where-Object { $_ -like 'plugin_pack-u_*' }).Count | Should -Be 0
    }
    It 'reads the config from CLAUDE_CONFIG_DIR when it is set and -UserHome is not' {
        $cfgDir = Join-Path $script:Root 'cfgdir'
        Write-Json (Join-Path $cfgDir '.claude.json') @{ mcpServers = @{ 'from-config-dir' = @{} } }
        # plugins/ and settings.json must come from the config dir too, not from the live ~/.claude.
        $pcfg = Join-Path $cfgDir 'p/cfg'; Write-Json (Join-Path $pcfg '.mcp.json') @{ 'cfg-server' = @{} }
        Write-Json (Join-Path $cfgDir 'plugins/installed_plugins.json') @{ version = 2; plugins = @{ 'cfgpack@m' = @(@{ scope = 'user'; installPath = $pcfg; lastUpdated = '2026-01-01' }) } }
        Write-Json (Join-Path $cfgDir 'settings.json') @{ enabledPlugins = @{ 'cfgpack@m' = $true } }
        $saved = $env:CLAUDE_CONFIG_DIR
        try {
            $env:CLAUDE_CONFIG_DIR = $cfgDir
            $n = @(& $script:Discover -Root $script:Repo2).prefix
            $n | Should -Contain 'from-config-dir'
            $n | Should -Contain 'plugin_cfgpack_cfg-server'
            # -UserHome still wins over the variable.
            @(& $script:Discover -Root $script:Repo2 -UserHome $script:Home2).prefix | Should -Not -Contain 'from-config-dir'
        } finally {
            $env:CLAUDE_CONFIG_DIR = $saved
        }
    }
    Context 'installs, scopes and manifest shapes' {
        BeforeAll {
            $script:Home3 = Join-Path $script:Root 'home3'
            $script:Repo3 = Join-Path $script:Root 'repo3'
            New-Item -ItemType Directory -Path $script:Repo3 -Force | Out-Null
            $repoKey = ($script:Repo3 -replace '\\','/')
            $old = Join-Path $script:Home3 'p/old'; $new = Join-Path $script:Home3 'p/new'
            Write-Json (Join-Path $old '.mcp.json') @{ 'old-server' = @{} }
            Write-Json (Join-Path $new '.mcp.json') @{ 'new-server' = @{} }
            $other = Join-Path $script:Home3 'p/other'; Write-Json (Join-Path $other '.mcp.json') @{ 'other-proj' = @{} }
            $mine  = Join-Path $script:Home3 'p/mine';  Write-Json (Join-Path $mine  '.mcp.json') @{ 'my.server' = @{} }
            $arr   = Join-Path $script:Home3 'p/arr'
            Write-Json (Join-Path $arr '.claude-plugin/plugin.json') @{ name = 'arr'; mcpServers = @('./a.json', './b.json') }
            Write-Json (Join-Path $arr 'a.json') @{ mcpServers = @{ 'from-a' = @{} } }
            Write-Json (Join-Path $arr 'b.json') @{ 'from-b' = @{} }
            $off = Join-Path $script:Home3 'p/off'; Write-Json (Join-Path $off '.mcp.json') @{ 'off-server' = @{} }
            # The newer install has the EARLIER month: a string sort of MM/dd/yyyy would pick the old one.
            Write-Json (Join-Path $script:Home3 '.claude/plugins/installed_plugins.json') @{ version = 2; plugins = @{
                'dated@m' = @(
                    @{ scope = 'user'; installPath = $old; lastUpdated = '2025-11-05T10:00:00.000Z' },
                    @{ scope = 'user'; installPath = $new; lastUpdated = '2026-02-10T10:00:00.000Z' })
                # The same pair in the opposite order: neither 'first' nor 'last' passes both.
                'dated2@m' = @(
                    @{ scope = 'user'; installPath = $new; lastUpdated = '2026-02-10T10:00:00.000Z' },
                    @{ scope = 'user'; installPath = $old; lastUpdated = '2025-11-05T10:00:00.000Z' })
                'projhere@m'  = @(@{ scope = 'project'; projectPath = $repoKey; installPath = $other; lastUpdated = '2026-01-01T00:00:00Z' })
                'elsewhere@m' = @(@{ scope = 'project'; projectPath = 'C:/some/other/repo'; installPath = $other; lastUpdated = '2026-01-01T00:00:00Z' })
                'mine@m'      = @(@{ scope = 'local'; projectPath = $repoKey; installPath = $mine; lastUpdated = '2026-01-01T00:00:00Z' })
                'arr@m'       = @(@{ scope = 'user'; installPath = $arr; lastUpdated = '2026-01-01T00:00:00Z' })
                'off@m'       = @(@{ scope = 'user'; installPath = $off; lastUpdated = '2026-01-01T00:00:00Z' })
            } }
            Write-Json (Join-Path $script:Home3 '.claude/settings.json') @{ enabledPlugins = @{ 'dated@m' = $true; 'dated2@m' = $true; 'elsewhere@m' = $true; 'mine@m' = $true; 'arr@m' = $true; 'off@m' = $true } }
            # projhere is enabled only by the project's own settings; off is switched off by the local ones.
            Write-Json (Join-Path $script:Repo3 '.claude/settings.json') @{ enabledPlugins = @{ 'projhere@m' = $true } }
            Write-Json (Join-Path $script:Repo3 '.claude/settings.local.json') @{ enabledPlugins = @{ 'off@m' = $false } }
            Push-Location $script:Repo3
            try { $script:Names3 = @(& $script:Discover -Root . -UserHome $script:Home3).prefix } finally { Pop-Location }
        }
        It 'picks the most recently updated install by date, not by its text' {
            $script:Names3 | Should -Contain 'plugin_dated_new-server'
            $script:Names3 | Should -Not -Contain 'plugin_dated_old-server'
            $script:Names3 | Should -Contain 'plugin_dated2_new-server'
            $script:Names3 | Should -Not -Contain 'plugin_dated2_old-server'
        }
        It 'counts a project-scope install only in its own project' {
            $script:Names3 | Should -Not -Contain 'plugin_elsewhere_other-proj'
            $script:Names3 | Should -Contain 'plugin_projhere_other-proj'     # same scope, this project, enabled by project settings
        }
        It 'resolves a relative -Root against the PowerShell location and normalizes names' {
            $script:Names3 | Should -Contain 'plugin_mine_my_server'
        }
        It 'reads every file of an array-valued mcpServers' {
            $script:Names3 | Should -Contain 'plugin_arr_from-a'
            $script:Names3 | Should -Contain 'plugin_arr_from-b'
            @($script:Names3 | Where-Object { $_ -match '_(Length|Count|Rank)$' }).Count | Should -Be 0
        }
        It 'honors a plugin disabled in the project settings' {
            $script:Names3 | Should -Not -Contain 'plugin_off_off-server'
        }
    }
    It 'returns nothing on an empty home' {
        $empty = Join-Path $script:Root 'empty'; New-Item -ItemType Directory -Path $empty -Force | Out-Null
        @(& $script:Discover -Root $empty -UserHome $empty).Count | Should -Be 0
    }
}
