#Requires -Modules Pester
<#  MCP servers registered twice by different plugins (#757).

    Everything runs over a FABRICATED Claude home and a fixture user config in $TestDrive: the real
    ~/.claude.json and the real plugin cache are never read or written. The plan must write nothing; the
    apply must back up first, touch only disabledMcpServers, refuse a plan id the user did not see, and
    leave every other value of the config byte-for-byte equal in meaning.  #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' | Resolve-Path
    $script:Script = Join-Path $script:Scripts 'Find-DuplicateMcpServers.ps1'
    $env:ABIOS_DUPMCP_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_DUPMCP_DOTSOURCE = ''
    . (Join-Path $PSScriptRoot 'PluginUpdate.TestKit.ps1')

    function script:New-Fx { New-FakeHome -Root (Join-Path $TestDrive ("h" + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    function script:Set-Mcp([string]$Dir, [string]$Body) { [System.IO.File]::WriteAllText((Join-Path $Dir '.mcp.json'), $Body) }

    # Two plugins bundling the same server: 'hosted' over http, 'local' as a stdio process. A third plugin
    # with a server nobody else has.
    function script:New-DupScenario {
        $fx = New-Fx
        $a = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'hosted' -Version '1.0' -Installed
        $b = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'local' -Version '1.0' -Installed
        $c = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'solo' -Version '1.0' -Installed
        Set-Mcp $a '{"mcpServers":{"model-mcp":{"type":"http","url":"https://example.invalid/mcp"}}}'
        Set-Mcp $b '{"model-mcp":{"command":"npx","args":["model-mcp","--start"]}}'
        Set-Mcp $c '{"mcpServers":{"other":{"command":"x"}}}'
        return $fx
    }

    function script:New-Config([string]$Body) {
        $p = Join-Path $TestDrive ("cfg" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        [System.IO.File]::WriteAllText($p, $Body)
        return $p
    }
    $script:CfgBody = @'
{
  "numStartups": 42,
  "firstStartTime": "2026-01-02T03:04:05.678Z",
  "note": "ñandú <tag> & \"quoted\"",
  "ratio": 1.50,
  "projects": {
    "C:/work/a": { "allowedTools": [], "disabledMcpServers": ["plugin:x:y"] },
    "C:/work/b": { "lastCost": 0.25 },
    "C:/work/c": { "disabledMcpServers": ["plugin:local:model-mcp"] }
  }
}
'@
}

Describe 'Get-PluginMcpServers - what one build declares' {
    It 'reads the wrapped and the bare .mcp.json, and mcpServers in plugin.json, with the transport of each' {
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Installed
        Set-Mcp $d '{"mcpServers":{"one":{"type":"sse","url":"https://x.invalid"}}}'
        [System.IO.File]::WriteAllText((Join-Path $d '.claude-plugin' 'plugin.json'), '{"name":"p","mcpServers":{"two":{"command":"node"},"three":{"url":"https://y.invalid"}}}')
        $s = @(Get-PluginMcpServers -Dir $d)
        ($s | Where-Object Server -eq 'one').Kind   | Should -Be 'hosted'
        ($s | Where-Object Server -eq 'two').Kind   | Should -Be 'local'
        ($s | Where-Object Server -eq 'three').Kind | Should -Be 'hosted'
    }

    It 'follows a plugin.json mcpServers path only inside the build' {
        $fx = New-Fx
        $d = Add-FakeBuild $fx -Marketplace 'm' -Plugin 'p' -Version '1.0' -Installed
        [System.IO.File]::WriteAllText((Join-Path $d 'servers.json'), '{"mcpServers":{"inside":{"command":"x"}}}')
        [System.IO.File]::WriteAllText((Join-Path $d '.claude-plugin' 'plugin.json'), '{"name":"p","mcpServers":"./servers.json"}')
        @(Get-PluginMcpServers -Dir $d).Server | Should -Be @('inside')
        [System.IO.File]::WriteAllText((Join-Path $TestDrive 'outside.json'), '{"mcpServers":{"outside":{"command":"x"}}}')
        [System.IO.File]::WriteAllText((Join-Path $d '.claude-plugin' 'plugin.json'), '{"name":"p","mcpServers":"../../../../../../outside.json"}')
        @(Get-PluginMcpServers -Dir $d).Count | Should -Be 0
    }
}

Describe 'Get-DuplicateMcpGroups - which one to keep' {
    It 'finds the server two plugins share, ignores the one only one plugin has, and keeps the hosted one by default' {
        $reg = Get-PluginMcpRegistrations -ClaudeHome (New-DupScenario).Root
        $reg.Ok | Should -BeTrue
        $g = @(Get-DuplicateMcpGroups -Registrations $reg.Items)
        $g.Count | Should -Be 1
        $g[0].Server | Should -Be 'model-mcp'
        $g[0].Keep.Id | Should -Be 'plugin:hosted:model-mcp'
        @($g[0].Disable.Id) | Should -Be @('plugin:local:model-mcp')
    }

    It 'keeps the local one with -PreferLocal, and the one the user names with -Keep' {
        $reg = Get-PluginMcpRegistrations -ClaudeHome (New-DupScenario).Root
        (Get-DuplicateMcpGroups -Registrations $reg.Items -PreferLocal)[0].Keep.Id | Should -Be 'plugin:local:model-mcp'
        (Get-DuplicateMcpGroups -Registrations $reg.Items -Keep 'plugin:local:model-mcp')[0].Keep.Id | Should -Be 'plugin:local:model-mcp'
    }

    It 'decides nothing when both share a transport and the user did not choose' {
        $rows = @(
            [pscustomobject]@{ Id = 'plugin:a:s'; Plugin = 'a'; Marketplace = 'm'; Server = 's'; Transport = 'stdio'; Kind = 'local' }
            [pscustomobject]@{ Id = 'plugin:b:s'; Plugin = 'b'; Marketplace = 'm'; Server = 's'; Transport = 'stdio'; Kind = 'local' }
        )
        $g = (Get-DuplicateMcpGroups -Registrations $rows)[0]
        $g.Keep | Should -BeNullOrEmpty
        @($g.Disable).Count | Should -Be 0
        $g.Reason | Should -Match '-Keep'
    }
}

Describe 'plan and apply on a fixture config' {
    BeforeEach {
        $script:Fx = New-DupScenario
        $script:Groups = @(Get-DuplicateMcpGroups -Registrations (Get-PluginMcpRegistrations -ClaudeHome $script:Fx.Root).Items)
        $script:Cfg = New-Config $script:CfgBody
        $script:Bk = Join-Path $TestDrive ("bk" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    It 'plans every known project that does not disable the redundant server yet, and writes nothing' {
        $before = [System.IO.File]::ReadAllBytes($script:Cfg)
        $plan = Get-McpDisablePlan -Config (Read-ClaudeConfig -Path $script:Cfg) -Groups $script:Groups
        @($plan.Missing.Project) | Should -Be @('C:/work/a', 'C:/work/b')
        $plan.PlanId | Should -Match '^[0-9a-f]{12}$'
        [System.IO.File]::ReadAllBytes($script:Cfg) | Should -Be $before
        Test-Path $script:Bk | Should -BeFalse
    }

    It 'applies the confirmed plan: backup first, only disabledMcpServers changes, verified after' {
        $plan = Get-McpDisablePlan -Config (Read-ClaudeConfig -Path $script:Cfg) -Groups $script:Groups
        $r = Invoke-McpDisable -ConfigPath $script:Cfg -Groups $script:Groups -PlanId $plan.PlanId -BackupDir $script:Bk
        $r.Ok | Should -BeTrue
        $r.Verified | Should -BeTrue
        $r.Added | Should -Be 2
        [System.IO.File]::ReadAllText($r.Backup) | Should -Be $script:CfgBody

        $after = [System.IO.File]::ReadAllText($script:Cfg) | ConvertFrom-Json -AsHashtable -DateKind String
        $orig  = $script:CfgBody | ConvertFrom-Json -AsHashtable -DateKind String
        $after.projects['C:/work/a'].disabledMcpServers | Should -Be @('plugin:x:y', 'plugin:local:model-mcp')
        $after.projects['C:/work/b'].disabledMcpServers | Should -Be @('plugin:local:model-mcp')
        $after.projects['C:/work/c'].disabledMcpServers | Should -Be @('plugin:local:model-mcp')
        # Everything else means exactly what it meant before.
        foreach ($p in $after.projects.Values) { $p.Remove('disabledMcpServers') }
        foreach ($p in $orig.projects.Values) { $p.Remove('disabledMcpServers') }
        ($after | ConvertTo-Json -Depth 20) | Should -Be ($orig | ConvertTo-Json -Depth 20)
        [System.IO.File]::ReadAllText($script:Cfg) | Should -Match 'ñandú <tag>'

        # A second plan finds nothing left to do.
        (Get-McpDisablePlan -Config (Read-ClaudeConfig -Path $script:Cfg) -Groups $script:Groups).Missing.Count | Should -Be 0
    }

    It 'refuses a plan id the user did not see, and changes nothing' {
        $before = [System.IO.File]::ReadAllBytes($script:Cfg)
        $r = Invoke-McpDisable -ConfigPath $script:Cfg -Groups $script:Groups -PlanId 'deadbeef0000' -BackupDir $script:Bk
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'changed since the plan'
        [System.IO.File]::ReadAllBytes($script:Cfg) | Should -Be $before
        Test-Path $script:Bk | Should -BeFalse
    }

    It 'refuses when a new project appeared after the plan (the plan id no longer matches)' {
        $plan = Get-McpDisablePlan -Config (Read-ClaudeConfig -Path $script:Cfg) -Groups $script:Groups
        [System.IO.File]::WriteAllText($script:Cfg, $script:CfgBody.Replace('"C:/work/c"', '"C:/work/new": {}, "C:/work/c"'))
        (Invoke-McpDisable -ConfigPath $script:Cfg -Groups $script:Groups -PlanId $plan.PlanId -BackupDir $script:Bk).Ok | Should -BeFalse
    }

    It 'never touches an unreadable config' {
        [System.IO.File]::WriteAllText($script:Cfg, '{ not json')
        $r = Invoke-McpDisable -ConfigPath $script:Cfg -Groups $script:Groups -PlanId 'x' -BackupDir $script:Bk
        $r.Ok | Should -BeFalse
        [System.IO.File]::ReadAllText($script:Cfg) | Should -Be '{ not json'
    }
}

Describe 'the script end to end (fixtures only)' {
    It 'plan run prints the duplicate and a plan id and leaves the config alone; -Execute without -PlanId refuses' {
        $fx = New-DupScenario
        $cfg = New-Config $script:CfgBody
        $before = [System.IO.File]::ReadAllBytes($cfg)
        $out = & pwsh -NoProfile -File $script:Script -ClaudeHome $fx.Root -ConfigPath $cfg -Json | Out-String
        $LASTEXITCODE | Should -Be 0
        $doc = $out | ConvertFrom-Json
        $doc.groups[0].keep | Should -Be 'plugin:hosted:model-mcp'
        $doc.planId | Should -Match '^[0-9a-f]{12}$'
        [System.IO.File]::ReadAllBytes($cfg) | Should -Be $before

        & pwsh -NoProfile -File $script:Script -ClaudeHome $fx.Root -ConfigPath $cfg -Execute -BackupDir (Join-Path $TestDrive 'bk-e2e') *> $null
        $LASTEXITCODE | Should -Be 1
        [System.IO.File]::ReadAllBytes($cfg) | Should -Be $before

        & pwsh -NoProfile -File $script:Script -ClaudeHome $fx.Root -ConfigPath $cfg -Execute -PlanId $doc.planId -BackupDir (Join-Path $TestDrive 'bk-e2e') *> $null
        $LASTEXITCODE | Should -Be 0
        ([System.IO.File]::ReadAllText($cfg) | ConvertFrom-Json -AsHashtable).projects['C:/work/b'].disabledMcpServers | Should -Be @('plugin:local:model-mcp')
    }
}
