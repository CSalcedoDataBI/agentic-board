#Requires -Modules Pester
<#  Skills-audit follow-ups (#462):
      1. a per-skill lint (no-triggers, first-person, ...) is reported once per VARIANT (same name +
         same description + same owner), not once per copy, and the report says how many it folded;
      2. a plugin skill's owner comes from the plugin's OWN manifest, never from a path segment
         (which is the marketplace name, or the literal word "marketplaces"); anything not positively
         established as the tool's own is local-only.

    All fixtures are temp directories with USERPROFILE pointed at a fake home for the run: the real
    ~/.claude is never read. The tests drive the real Get-SkillInventory.ps1, Invoke-SkillAudit.ps1
    and Resolve-SkillOwner.ps1. #>

BeforeAll {
    $script:Scripts  = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Engine   = Join-Path $script:Scripts 'Get-SkillInventory.ps1'
    $script:Audit    = Join-Path $script:Scripts 'Invoke-SkillAudit.ps1'
    $script:Resolver = Join-Path $script:Scripts 'Resolve-SkillOwner.ps1'
    $script:Tmp      = Join-Path ([System.IO.Path]::GetTempPath()) ('skillowner-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:SavedProfile = $env:USERPROFILE
    $script:ToolRepo = 'CSalcedoDataBI/agentic-board'
    $script:ToolHome = 'https://github.com/CSalcedoDataBI/agentic-board'

    function New-Fixture {
        param([string]$Tag)
        $base = Join-Path $script:Tmp $Tag
        $root = Join-Path $base 'repo'
        $home_ = Join-Path $base 'home'
        New-Item -ItemType Directory -Path $root, $home_ -Force | Out-Null
        [pscustomobject]@{ Root = $root; Home = $home_ }
    }
    function New-Skill {
        param([string]$Base, [string]$RelDir, [string]$Name, [string]$Description)
        $dir = Join-Path $Base $RelDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8 -Value "---`nname: $Name`ndescription: $Description`n---`nBody"
    }
    function Set-Json {
        param([string]$Base, [string]$RelFile, [string]$Text)
        $f = Join-Path $Base $RelFile
        New-Item -ItemType Directory -Path (Split-Path $f -Parent) -Force | Out-Null
        Set-Content -LiteralPath $f -Encoding utf8 -Value $Text
    }
    function Set-Manifest {
        # A plugin.json at <RelPluginDir>/.claude-plugin/plugin.json
        param([string]$Base, [string]$RelPluginDir, [string]$Json)
        Set-Json $Base "$RelPluginDir/.claude-plugin/plugin.json" $Json
    }
    function Invoke-Inv {
        param($Fx)
        $env:USERPROFILE = $Fx.Home
        try { & $script:Engine -Root $Fx.Root -Scope all -TimeoutSeconds 0 } finally { $env:USERPROFILE = $script:SavedProfile }
    }
    function Invoke-Aud {
        param($Fx, [string]$CurrentRepo = 'me/repo')
        $env:USERPROFILE = $Fx.Home
        try { & $script:Audit -Root $Fx.Root -Scope all -CurrentRepo $CurrentRepo } finally { $env:USERPROFILE = $script:SavedProfile }
    }
    $script:ToolManifest = '{"name":"agentic-board","homepage":"' + $script:ToolHome + '"}'
    # The tool's skill as it is seen in four places at once.
    function New-ToolCopies {
        param($Fx, [string]$Name, [string]$Description, [string]$CacheDescription = $Description)
        New-Skill $Fx.Root "plugins/agentic-board/skills/$Name" $Name $Description
        New-Skill $Fx.Root ".claude/worktrees/wt1/plugins/agentic-board/skills/$Name" $Name $Description
        Set-Manifest $Fx.Home '.claude/plugins/cache/mkt1/agentic-board/0.40.0' $script:ToolManifest
        New-Skill $Fx.Home ".claude/plugins/cache/mkt1/agentic-board/0.40.0/skills/$Name" $Name $CacheDescription
        Set-Manifest $Fx.Home '.claude/plugins/marketplaces/mkt1/plugins/agentic-board' $script:ToolManifest
        New-Skill $Fx.Home ".claude/plugins/marketplaces/mkt1/plugins/agentic-board/skills/$Name" $Name $Description
    }
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    if ($script:Tmp -and (Test-Path $script:Tmp)) { Remove-Item $script:Tmp -Recurse -Force }
}

Describe 'plugin identity is read from the manifest, not from a path segment (#462)' {
    It 'the installed cache (marketplace/plugin/version directories) is the plugin, not the marketplace' {
        $fx = New-Fixture 'id-cache'
        Set-Manifest $fx.Home '.claude/plugins/cache/some-market/agentic-board/0.40.0' $script:ToolManifest
        New-Skill $fx.Home '.claude/plugins/cache/some-market/agentic-board/0.40.0/skills/s1' 's1' 'Does a thing. Use when asked.'
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 's1'
        $r.plugin | Should -Be 'agentic-board'
        $r.namespace | Should -Be 'agentic-board:s1'
        $r.pluginRepo | Should -Be $script:ToolRepo
        $r.pluginIdentity | Should -Be 'plugin.json'
    }
    It 'a marketplaces clone (marketplaces/NAME/plugins/PLUGIN) is the plugin, not the word "marketplaces"' {
        $fx = New-Fixture 'id-mkt'
        Set-Manifest $fx.Home '.claude/plugins/marketplaces/some-market/plugins/agentic-board' $script:ToolManifest
        New-Skill $fx.Home '.claude/plugins/marketplaces/some-market/plugins/agentic-board/skills/s1' 's1' 'Does a thing. Use when asked.'
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 's1'
        $r.plugin | Should -Be 'agentic-board'
        $r.plugin | Should -Not -Be 'marketplaces'
    }
    It 'reads repository (string, github: shorthand, object with .git url) and falls back to homepage' {
        $fx = New-Fixture 'id-repo'
        $cases = [ordered]@{
            'r1' = '{"name":"p1","repository":"someone/p1"}'
            'r2' = '{"name":"p2","repository":"github:someone/p2"}'
            'r3' = '{"name":"p3","repository":{"type":"git","url":"git+https://github.com/someone/p3.git"}}'
            'r4' = '{"name":"p4","homepage":"https://github.com/someone/p4#readme"}'
            'r5' = '{"name":"p5","homepage":"https://example.com/p5"}'
        }
        foreach ($k in $cases.Keys) {
            Set-Manifest $fx.Home ".claude/plugins/cache/m/$k/1" $cases[$k]
            New-Skill $fx.Home ".claude/plugins/cache/m/$k/1/skills/$k" $k 'Does a thing. Use when asked.'
        }
        $inv = Invoke-Inv $fx
        ($inv.skills | Where-Object name -eq 'r1').pluginRepo | Should -Be 'someone/p1'
        ($inv.skills | Where-Object name -eq 'r2').pluginRepo | Should -Be 'someone/p2'
        ($inv.skills | Where-Object name -eq 'r3').pluginRepo | Should -Be 'someone/p3'
        ($inv.skills | Where-Object name -eq 'r4').pluginRepo | Should -Be 'someone/p4'
        ($inv.skills | Where-Object name -eq 'r5').pluginRepo | Should -BeNullOrEmpty
    }
    It 'a marketplace.json entry with a local source establishes the plugin when there is no plugin.json' {
        $fx = New-Fixture 'id-entry'
        Set-Json $fx.Home '.claude/plugins/marketplaces/mk/.claude-plugin/marketplace.json' '{"name":"mk","plugins":[{"name":"entry-plugin","source":"./plugins/ep"},{"name":"other","source":"./plugins/other"}]}'
        New-Skill $fx.Home '.claude/plugins/marketplaces/mk/plugins/ep/skills/z' 'z' 'Does a thing. Use when asked.'
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 'z'
        $r.plugin | Should -Be 'entry-plugin'
        $r.pluginIdentity | Should -Be 'marketplace.json'
        $r.pluginRepo | Should -BeNullOrEmpty
    }
    It 'a home spelled with 8.3 short names (CRISTO~1) still identifies the plugin instead of silently failing to unknown' -Skip:(-not $IsWindows) {
        $fx = New-Fixture 'id-short-home'
        Set-Manifest $fx.Home '.claude/plugins/cache/some-market/agentic-board/0.40.0' $script:ToolManifest
        New-Skill $fx.Home '.claude/plugins/cache/some-market/agentic-board/0.40.0/skills/s1' 's1' 'Does a thing. Use when asked.'
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($fx.Home).ShortPath
        if ($short -ceq $fx.Home) { Set-ItResult -Skipped -Because 'this volume has no 8.3 short name for the fixture'; return }
        $short | Should -Not -Be $fx.Home
        $env:USERPROFILE = $short
        try { $inv = & $script:Engine -Root $fx.Root -Scope plugin -TimeoutSeconds 0 } finally { $env:USERPROFILE = $script:SavedProfile }
        $r = $inv.skills | Where-Object name -eq 's1'
        $r.pluginIdentity | Should -Be 'plugin.json'
        $r.plugin | Should -Be 'agentic-board'
    }
    It 'no manifest at all is UNKNOWN: no plugin, no namespace prefix, nothing guessed from the path' {
        $fx = New-Fixture 'id-none'
        New-Skill $fx.Home '.claude/plugins/cache/mkt3/nomanifest/1/skills/y' 'y' 'Does a thing. Use when asked.'
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 'y'
        $r.plugin | Should -BeNullOrEmpty
        $r.pluginIdentity | Should -Be 'unknown'
        $r.namespace | Should -Be 'y'
    }
    It 'an unreadable plugin.json is UNKNOWN, and the walk does not borrow a parent manifest' {
        $fx = New-Fixture 'id-bad'
        Set-Manifest $fx.Home '.claude/plugins/cache/m/outer' $script:ToolManifest
        Set-Manifest $fx.Home '.claude/plugins/cache/m/outer/inner' '{ this is not json'
        New-Skill $fx.Home '.claude/plugins/cache/m/outer/inner/skills/q' 'q' 'Does a thing. Use when asked.'
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 'q'
        $r.pluginIdentity | Should -Be 'unknown'
        $r.plugin | Should -BeNullOrEmpty
    }
    It 'two marketplace entries claiming the same directory are ambiguous, hence unknown' {
        $fx = New-Fixture 'id-ambig'
        Set-Json $fx.Home '.claude/plugins/marketplaces/mk/.claude-plugin/marketplace.json' '{"name":"mk","plugins":[{"name":"one","source":"./plugins/ep"},{"name":"two","source":"./plugins/ep"}]}'
        New-Skill $fx.Home '.claude/plugins/marketplaces/mk/plugins/ep/skills/z' 'z' 'Does a thing. Use when asked.'
        ((Invoke-Inv $fx).skills | Where-Object name -eq 'z').pluginIdentity | Should -Be 'unknown'
    }
}

Describe 'repository URLs only count when the host is github.com (review round 1)' {
    It 'a manifest declaring a look-alike host does not become a GitHub slug, so the plugin is not filed' {
        $fx = New-Fixture 'hosts'
        $cases = [ordered]@{
            'h1' = 'https://notgithub.com/CSalcedoDataBI/agentic-board'
            'h2' = 'https://github.com.evil.io/CSalcedoDataBI/agentic-board'
            'h3' = 'https://gitlab.com/CSalcedoDataBI/agentic-board'
            'h4' = 'gitlab:CSalcedoDataBI/agentic-board'
            'h5' = 'git@notgithub.com:CSalcedoDataBI/agentic-board.git'
        }
        foreach ($k in $cases.Keys) {
            Set-Manifest $fx.Home ".claude/plugins/cache/m/$k/1" ('{"name":"agentic-board","homepage":"' + $cases[$k] + '"}')
            New-Skill $fx.Home ".claude/plugins/cache/m/$k/1/skills/$k" $k 'I can help with things.'
        }
        $inv = Invoke-Inv $fx
        foreach ($k in $cases.Keys) { ($inv.skills | Where-Object name -eq $k).pluginRepo | Should -BeNullOrEmpty }
        $aud = Invoke-Aud $fx
        @($aud.findings | Where-Object filing -eq 'file').Count | Should -Be 0
    }
    It 'the real GitHub spellings are all accepted' {
        $fx = New-Fixture 'hosts-ok'
        $cases = [ordered]@{
            'g1' = 'https://github.com/o/g1'
            'g2' = 'git+https://github.com/o/g2.git'
            'g3' = 'git@github.com:o/g3.git'
            'g4' = 'ssh://git@github.com/o/g4'
            'g5' = 'github:o/g5'
            'g6' = 'o/g6'
            'g7' = 'https://www.github.com/o/g7/tree/main'
        }
        foreach ($k in $cases.Keys) {
            Set-Manifest $fx.Home ".claude/plugins/cache/m/$k/1" ('{"name":"' + $k + '","repository":"' + $cases[$k] + '"}')
            New-Skill $fx.Home ".claude/plugins/cache/m/$k/1/skills/$k" $k 'Does a thing. Use when asked.'
        }
        $inv = Invoke-Inv $fx
        foreach ($k in $cases.Keys) { ($inv.skills | Where-Object name -eq $k).pluginRepo | Should -Be "o/$k" }
    }
}

Describe 'a manifest nested inside skills/ cannot name its own plugin (review round 1)' {
    It 'a plugin.json (or marketplace.json) dropped in skills/NAME/.claude-plugin is ignored; the real plugin root wins' {
        $fx = New-Fixture 'nested'
        Set-Manifest $fx.Home '.claude/plugins/cache/m/realplugin/1' '{"name":"realplugin","repository":"someone/realplugin"}'
        New-Skill $fx.Home '.claude/plugins/cache/m/realplugin/1/skills/leak' 'leak' 'I can help with things.'
        Set-Manifest $fx.Home '.claude/plugins/cache/m/realplugin/1/skills/leak' $script:ToolManifest
        $r = (Invoke-Inv $fx).skills | Where-Object name -eq 'leak'
        $r.plugin | Should -Be 'realplugin'
        (Invoke-Aud $fx).findings | Where-Object { $_.filing -eq 'file' } | Should -BeNullOrEmpty
    }
    It 'a skill outside any skills/ directory has no plugin layout, hence unknown' {
        $fx = New-Fixture 'no-skills-dir'
        Set-Manifest $fx.Home '.claude/plugins/cache/m/p/1' $script:ToolManifest
        New-Skill $fx.Home '.claude/plugins/cache/m/p/1/elsewhere/z' 'z' 'Does a thing. Use when asked.'
        ((Invoke-Inv $fx).skills | Where-Object name -eq 'z').pluginIdentity | Should -Be 'unknown'
    }
}

Describe 'folding never hides a finding a copy would have produced (review round 1)' {
    It 'copies whose descriptions differ only in whitespace but not in over-budget status are not folded' {
        $fx = New-Fixture 'fold-budget'
        $tail = 'not for unrelated work.'
        New-Skill $fx.Root 'plugins/agentic-board/skills/demo' 'demo' "Use when asked; $tail"
        Set-Manifest $fx.Home '.claude/plugins/cache/m/agentic-board/1' $script:ToolManifest
        New-Skill $fx.Home '.claude/plugins/cache/m/agentic-board/1/skills/demo' 'demo' ('Use when asked;' + (' ' * 1600) + $tail)
        $aud = Invoke-Aud $fx $script:ToolRepo
        @($aud.findings | Where-Object type -eq 'over-budget').Count | Should -Be 1
    }
}

Describe 'owner routing is fail-closed (#462)' {
    It 'Resolve-SkillOwner: the tool is the tool only when name AND declared repo agree' {
        $o = & $script:Resolver -Scope plugin -Plugin agentic-board -PluginRepo $script:ToolRepo
        $o.filing | Should -Be 'file'
        $o.ownerRepo | Should -Be $script:ToolRepo
        (& $script:Resolver -Scope plugin -Plugin agentic-bi-ops -PluginRepo 'csalcedodatabi/AGENTIC-BOARD').filing | Should -Be 'file'
    }
    It 'Resolve-SkillOwner: a plugin that only CALLS itself agentic-board is local-only' {
        foreach ($repo in 'evil/agentic-board', '', 'not a repo') {
            $o = & $script:Resolver -Scope plugin -Plugin agentic-board -PluginRepo $repo
            $o.filing | Should -Be 'local'
            $o.ownerRepo | Should -Not -Be $script:ToolRepo
        }
    }
    It 'Resolve-SkillOwner: an unidentified plugin is local-only and ownerRepo is never a name' {
        $o = & $script:Resolver -Scope plugin -PluginRepo ''
        $o.filing | Should -Be 'local'
        $o.ownerRepo | Should -BeNullOrEmpty
        $t = & $script:Resolver -Scope plugin -Plugin some-market -PluginRepo 'someone/tool'
        $t.filing | Should -Be 'local'
        $t.ownerRepo | Should -Be 'someone/tool'
        (& $script:Resolver -Scope plugin -Plugin some-market).ownerRepo | Should -BeNullOrEmpty
    }
    It 'the audit never yields an ownerRepo that is a marketplace/plugin name, and files only the verified tool' {
        $fx = New-Fixture 'route'
        # tool, verified
        New-ToolCopies $fx 'tool-skill' 'I can help with tool things.'
        # third party with a declared repo
        Set-Manifest $fx.Home '.claude/plugins/cache/mkt2/other/2.0' '{"name":"other","repository":"someone/other"}'
        New-Skill $fx.Home '.claude/plugins/cache/mkt2/other/2.0/skills/o1' 'o1' 'I can help with other things.'
        # third party with no manifest
        New-Skill $fx.Home '.claude/plugins/cache/mkt3/nomanifest/1/skills/n1' 'n1' 'I can help with nameless things.'
        # spoof: calls itself agentic-board, declares someone else's repo
        Set-Manifest $fx.Home '.claude/plugins/cache/mkt4/spoof/1' '{"name":"agentic-board","homepage":"https://github.com/evil/spoof"}'
        New-Skill $fx.Home '.claude/plugins/cache/mkt4/spoof/1/skills/sp1' 'sp1' 'I can help with spoofed things.'
        # spoof: calls itself agentic-board, declares nothing
        Set-Manifest $fx.Home '.claude/plugins/cache/mkt5/quiet/1' '{"name":"agentic-board"}'
        New-Skill $fx.Home '.claude/plugins/cache/mkt5/quiet/1/skills/sp2' 'sp2' 'I can help with quiet things.'

        $aud = Invoke-Aud $fx
        $owners = @($aud.findings.ownerRepo | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($bad in 'marketplaces', 'mkt1', 'mkt2', 'mkt3', 'mkt4', 'mkt5', 'cache', 'other', 'nomanifest', 'spoof', 'quiet') { $owners | Should -Not -Contain $bad }
        $owners | Should -Contain $script:ToolRepo
        @($aud.findings | Where-Object { $_.filing -eq 'file' -and $_.ownerRepo -ne $script:ToolRepo -and $_.scope -eq 'plugin' }).Count | Should -Be 0
        # only the verified tool skill is filed from plugin scope
        @($aud.findings | Where-Object { $_.scope -eq 'plugin' -and $_.filing -eq 'file' } | ForEach-Object skill | Sort-Object -Unique) | Should -Be @('agentic-board:tool-skill')
        foreach ($sk in 'other:o1', 'n1', 'agentic-board:sp1', 'agentic-board:sp2') {
            $f = @($aud.findings | Where-Object skill -eq $sk)
            $f.Count | Should -BeGreaterThan 0
            @($f | Where-Object filing -ne 'local').Count | Should -Be 0
        }
        (@($aud.findings | Where-Object skill -eq 'other:o1')[0]).ownerRepo | Should -Be 'someone/other'
        (@($aud.findings | Where-Object skill -eq 'n1')[0]).ownerRepo | Should -BeNullOrEmpty
    }
}

Describe 'a per-skill lint is reported once per skill, not once per copy (#462)' {
    It 'four copies of one badly-worded skill give ONE finding per lint, saying how many copies it stands for' {
        $fx = New-Fixture 'fold4'
        New-ToolCopies $fx 'tool-skill' 'I can help with tool things.'
        $aud = Invoke-Aud $fx $script:ToolRepo      # the repo tree and the plugin copies share one owner here
        $inv = Invoke-Inv $fx
        @($inv.skills).Count | Should -Be 4
        $f = @($aud.findings | Where-Object type -in 'first-person', 'no-triggers', 'no-when-not')
        $f.Count | Should -Be 3
        foreach ($x in $f) { $x.copies | Should -Be 4; @($x.paths).Count | Should -Be 4 }
        $aud.summary.findings | Should -Be 3
        $aud.summary.perCopyFindingsFolded | Should -Be 9       # 3 lints x 3 folded copies
        # and the finding sits on the most local copy: the repo tree, not a worktree or the cache
        ($f | Select-Object -First 1).scope | Should -Be 'project'
    }
    It 'copies that differ in owner are NOT folded: each owner keeps its finding (routing never changes)' {
        $fx = New-Fixture 'fold-owner'
        New-ToolCopies $fx 'tool-skill' 'I can help with tool things.'
        $aud = Invoke-Aud $fx 'me/private-project'   # the repo tree belongs to a different repo than the plugin copies
        $nt = @($aud.findings | Where-Object type -eq 'no-triggers')
        $nt.Count | Should -Be 2
        @($nt.ownerRepo | Sort-Object) | Should -Be @('CSalcedoDataBI/agentic-board', 'me/private-project')
        (@($nt | Where-Object ownerRepo -eq 'me/private-project')[0]).copies | Should -Be 2     # tree + worktree
        (@($nt | Where-Object ownerRepo -eq $script:ToolRepo)[0]).copies | Should -Be 2         # cache + marketplaces
    }
    It 'a copy whose description differs is its own variant and keeps its own findings' {
        $fx = New-Fixture 'fold-diff'
        New-ToolCopies $fx 'tool-skill' 'I can help with tool things.' 'I can help with an older wording entirely.'
        $aud = Invoke-Aud $fx $script:ToolRepo
        $nt = @($aud.findings | Where-Object type -eq 'no-triggers')
        $nt.Count | Should -Be 2
        @($nt.copies | Sort-Object) | Should -Be @(1, 3)
    }
    It 'per-file defects stay per file: two misplaced copies are two findings while the wording lint is one' {
        $fx = New-Fixture 'fold-file'
        New-Skill $fx.Root 'loose/a/thing' 'thing' 'I can help with loose things.'
        New-Skill $fx.Root 'loose/b/thing' 'thing' 'I can help with loose things.'
        $aud = Invoke-Aud $fx
        @($aud.findings | Where-Object type -eq 'misplaced').Count | Should -Be 2
        @($aud.findings | Where-Object type -eq 'no-triggers').Count | Should -Be 1
    }
    It 'a missing frontmatter name is a defect of each FILE: two nameless copies are two findings' {
        $fx = New-Fixture 'fold-nameless'
        foreach ($d in '.claude/skills/p/nameless', '.claude/skills/q/nameless') {
            $dir = Join-Path $fx.Root $d
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'SKILL.md') -Encoding utf8 -Value "---`ndescription: I can help with nameless things.`n---`nBody"
        }
        $aud = Invoke-Aud $fx
        @($aud.findings | Where-Object type -eq 'missing-name').Count | Should -Be 2
        @($aud.findings | Where-Object type -eq 'no-triggers').Count | Should -Be 1
    }
    It 'empty-description copies fold to one high finding and skip the wording lints, as before' {
        $fx = New-Fixture 'fold-empty'
        New-Skill $fx.Root 'plugins/agentic-board/skills/blank' 'blank' ''
        New-Skill $fx.Root '.claude/worktrees/wt1/plugins/agentic-board/skills/blank' 'blank' ''
        $aud = Invoke-Aud $fx
        @($aud.findings | Where-Object type -eq 'empty-description').Count | Should -Be 1
        @($aud.findings | Where-Object type -in 'no-triggers', 'first-person').Count | Should -Be 0
        $aud.summary.perCopyFindingsFolded | Should -Be 1
    }
    It 'a single copy is unchanged: one finding, copies = 1, nothing folded' {
        $fx = New-Fixture 'fold-one'
        New-Skill $fx.Root '.claude/skills/p/solo' 'solo' 'I can help with solo things.'
        $aud = Invoke-Aud $fx
        $aud.summary.perCopyFindingsFolded | Should -Be 0
        foreach ($x in @($aud.findings | Where-Object type -in 'first-person', 'no-triggers')) { $x.copies | Should -Be 1 }
    }
}
