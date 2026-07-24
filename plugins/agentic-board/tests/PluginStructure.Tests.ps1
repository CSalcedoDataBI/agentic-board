#Requires -Modules Pester
<#  Marketplace structure check: every plugin source must ship a plugin.json (#420).

    Motivation, from inbox/IMPROVEMENTS.md (2026-06-26, "plugin packaging: root-as-plugin is
    rejected by the installer"): `/plugin marketplace add` SILENTLY rejects a plugin whose
    `source.path` does not contain a `.claude-plugin/plugin.json` — it never registers, and the
    only symptom the user sees is "Unknown command" when they try the slash command. Nothing
    catches this today; a path typo or a moved plugin dir would ship undetected.

    This is the cheapest guard against it: a pure filesystem assertion, no network and no token,
    that reads the repo-root marketplace manifest and proves each git-subdir source still points at
    a real plugin. It fails closed — an unreadable/empty manifest is a red test, never a vacuous
    pass. CI already runs this suite, so it becomes a blocking merge gate automatically. #>

BeforeDiscovery {
    # Discovery-time on purpose: one `It` per plugin entry, so a failure names the offending
    # plugin in the test name instead of hiding inside one aggregate assertion.
    #   tests/ -> agentic-board/ -> plugins/ -> repo root
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path
    $script:MarketplacePath = Join-Path $script:RepoRoot '.claude-plugin' 'marketplace.json'

    $script:PluginEntries = @()
    if (Test-Path $script:MarketplacePath) {
        $manifest = Get-Content $script:MarketplacePath -Raw | ConvertFrom-Json
        $script:PluginEntries = @(
            foreach ($p in @($manifest.plugins)) {
                # Only git-subdir sources carry a repo-relative path we can check on disk. Other
                # source kinds (e.g. remote git) are out of scope for a filesystem assertion.
                if ($p.source.source -eq 'git-subdir' -and $p.source.path) {
                    @{
                        Name         = $p.name
                        SubPath      = $p.source.path
                        ExpectedJson = Join-Path $script:RepoRoot $p.source.path '.claude-plugin' 'plugin.json'
                    }
                }
            }
        )
    }
}

Describe 'marketplace.json plugin structure' {
    It 'the marketplace manifest exists at the repo root' {
        $script:MarketplacePath = Join-Path (Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path) '.claude-plugin' 'marketplace.json'
        Test-Path $script:MarketplacePath | Should -BeTrue
    }

    It 'the manifest is valid JSON with at least one plugin entry' {
        $mp = Join-Path (Join-Path $PSScriptRoot '..' '..' '..' | Resolve-Path) '.claude-plugin' 'marketplace.json'
        $manifest = Get-Content $mp -Raw | ConvertFrom-Json
        @($manifest.plugins).Count | Should -BeGreaterThan 0
    }

    # Fails closed: if the manifest moves or the parse yields no git-subdir sources, this red test
    # fires instead of Pester generating zero per-plugin tests and passing in silence.
    It 'discovers at least one git-subdir plugin source to check' -ForEach @{
        Found = @($script:PluginEntries).Count
    } {
        $Found | Should -BeGreaterThan 0
    }

    It 'plugin <_.Name> (<_.SubPath>) ships a .claude-plugin/plugin.json' -ForEach $script:PluginEntries {
        # A missing plugin.json is exactly the failure that makes the installer silently drop the
        # plugin, so the message points straight at the path the manifest promised.
        Test-Path $_.ExpectedJson | Should -BeTrue -Because "marketplace.json points '$($_.Name)' at '$($_.SubPath)', which must contain .claude-plugin/plugin.json or the installer rejects it"
    }
}
