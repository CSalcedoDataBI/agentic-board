#Requires -Modules Pester
<#  Tests for how /board expert resolves the things a role points at, and how fast it scans (#469, #609).

    - Find-AgentDefinition (#469): resolves by the name the Agent tool shows (frontmatter `name`),
      accepts the `stem.agent.md` suffix, and still reports a genuinely absent agent as absent.
    - Find-FilesPruned / Get-SkillInventory (#609): excluded directories are never ENTERED, an
      expired budget yields a loud partial result, and the faster near-duplicate pass returns
      exactly what the naive one did.
    - Expert-Roles.ps1 -List (#609/#469): prints a progress line before it scans, and its AGENT
      column says which role lost its persona.

    Everything runs against real fixture trees and the real scripts; nothing is mocked. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $env:ABIOS_EXPERTROLE_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Expert-RoleSynthesis.ps1')
    $env:ABIOS_EXPERTROLE_DOTSOURCE = ''

    function New-TempDir([string]$Tag) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("$Tag-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $d
    }
    function New-AgentFile {
        param([string]$Root, [string]$RelPath, [string]$Name, [string]$Body = 'You are a careful reviewer.')
        $p = Join-Path $Root $RelPath
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        $fm = if ($Name) { "---`nname: $Name`ndescription: fixture agent`n---`n" } else { '' }
        Set-Content -LiteralPath $p -Value ($fm + $Body) -Encoding utf8
        $p
    }
    $script:Dirs = [System.Collections.Generic.List[string]]::new()
    function New-Tracked([string]$Tag) { $d = New-TempDir $Tag; $script:Dirs.Add($d); $d }
}

AfterAll {
    foreach ($d in $script:Dirs) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

Describe 'Find-AgentDefinition resolves what the Agent tool lists (#469)' {
    BeforeAll {
        $script:Cache = New-Tracked 'agents-cache'
        # stem.agent.md — 12 of the 18 definitions installed on a stock machine look like this.
        $script:DenebAgent = New-AgentFile $script:Cache 'power-bi/reports/1.0/agents/deneb-reviewer.agent.md' 'deneb-reviewer'
        # The wshobson/agents shape: the file stem and the registered name DIVERGE.
        $script:CodeRev    = New-AgentFile $script:Cache 'wshobson/comprehensive-review/agents/code-reviewer.md' 'comprehensive-review-code-reviewer'
        # Plain stem.md that already worked (regression guard).
        $script:Plain      = New-AgentFile $script:Cache 'sdk/agents/agent-sdk-verifier-py.md' 'agent-sdk-verifier-py'
        # No frontmatter at all: only the stem can identify it.
        $script:NoFm       = New-AgentFile $script:Cache 'misc/agents/bare-agent.md' $null
        # No frontmatter AND the .agent suffix: nothing but the stem-without-suffix can name it.
        $script:NoFmSuffix = New-AgentFile $script:Cache 'misc/agents/plain-thing.agent.md' $null
        $script:Roots      = @($script:Cache)
    }

    It 'resolves a stem.agent.md definition by its bare name' {
        Find-AgentDefinition -Name 'deneb-reviewer' -SearchRoots $script:Roots | Should -Be $script:DenebAgent
    }
    It 'resolves a stem.agent.md definition by the namespaced name the Agent tool shows' {
        Find-AgentDefinition -Name 'reports:deneb-reviewer' -SearchRoots $script:Roots | Should -Be $script:DenebAgent
    }
    It 'resolves by the frontmatter name when it differs from the file stem' {
        Find-AgentDefinition -Name 'comprehensive-review-code-reviewer' -SearchRoots $script:Roots | Should -Be $script:CodeRev
    }
    It 'still resolves that same definition by its file stem' {
        Find-AgentDefinition -Name 'code-reviewer' -SearchRoots $script:Roots | Should -Be $script:CodeRev
    }
    It 'keeps resolving a plain stem.md definition' {
        Find-AgentDefinition -Name 'agent-sdk-verifier-py' -SearchRoots $script:Roots | Should -Be $script:Plain
    }
    It 'resolves a definition that has no frontmatter by its stem' {
        Find-AgentDefinition -Name 'bare-agent' -SearchRoots $script:Roots | Should -Be $script:NoFm
    }
    It 'resolves a stem.agent.md definition with no frontmatter by its stem without the suffix' {
        Find-AgentDefinition -Name 'plain-thing' -SearchRoots $script:Roots | Should -Be $script:NoFmSuffix
    }
    It 'matches case-insensitively' {
        Find-AgentDefinition -Name 'Deneb-Reviewer' -SearchRoots $script:Roots | Should -Be $script:DenebAgent
    }
    It 'reports a genuinely absent agent as absent (the honest path stays honest)' {
        Find-AgentDefinition -Name 'not-installed-anywhere' -SearchRoots $script:Roots | Should -BeNullOrEmpty
        Find-AgentDefinition -Name 'plugin:not-installed-anywhere' -SearchRoots $script:Roots | Should -BeNullOrEmpty
    }
    It 'does not resolve a markdown file that is not under an agents/ directory' {
        $stray = New-AgentFile $script:Cache 'docs/notes/stray-agent.md' 'stray-agent'
        Find-AgentDefinition -Name 'stray-agent' -SearchRoots $script:Roots | Should -BeNullOrEmpty
    }
    It 'prefers a frontmatter-name match over an unrelated file that merely has that stem' {
        $root = New-Tracked 'agents-prio'
        $byStem = New-AgentFile $root 'a/agents/helper.md' 'something-else'
        $byName = New-AgentFile $root 'b/agents/other-file.md' 'helper'
        Find-AgentDefinition -Name 'helper' -SearchRoots @($root) | Should -Be $byName
    }
    It 'uses the namespace to break a tie between two candidates' {
        $root = New-Tracked 'agents-ns'
        $a = New-AgentFile $root 'alpha/agents/reviewer.md' 'reviewer'
        $b = New-AgentFile $root 'beta/agents/reviewer.md'  'reviewer'
        Find-AgentDefinition -Name 'beta:reviewer'  -SearchRoots @($root) | Should -Be $b
        Find-AgentDefinition -Name 'alpha:reviewer' -SearchRoots @($root) | Should -Be $a
    }
    It 'a namespace that matches no candidate never makes an installed agent unresolvable (documented: it only breaks ties)' {
        $root = New-Tracked 'agents-ns-miss'
        $a = New-AgentFile $root 'alpha/agents/reviewer.md' 'reviewer'
        New-AgentFile $root 'beta/agents/reviewer.md' 'reviewer' | Out-Null
        # 'gamma' owns neither: the first candidate in root order is returned, not $null.
        Find-AgentDefinition -Name 'gamma:reviewer' -SearchRoots @($root) | Should -Be $a
    }
    It 'keeps root order: a project definition outranks the same name in a later root' {
        $proj  = New-Tracked 'agents-proj'
        $later = New-Tracked 'agents-later'
        $p = New-AgentFile $proj  '.claude/agents/reviewer.md' 'reviewer'
        $l = New-AgentFile $later 'x/agents/reviewer.md'       'reviewer'
        Find-AgentDefinition -Name 'reviewer' -SearchRoots @($proj, $later) | Should -Be $p
    }
    It 'builds its index under a time budget: an exhausted budget yields a partial index and a warning' {
        $w = @()
        $idx = Get-AgentDefinitionIndex -SearchRoots $script:Roots -TimeoutSeconds 0.0001 -WarningVariable w -WarningAction SilentlyContinue
        $idx.byName.Count | Should -Be 0
        $idx.byStem.Count | Should -Be 0
        (@($w) -join ' ') | Should -Match 'PARTIAL'
    }
    It 'can be handed a prebuilt index, so many lookups walk the roots once' {
        $idx = Get-AgentDefinitionIndex -SearchRoots $script:Roots
        # Remove the tree: a lookup that re-walked would now fail; one served by the index does not.
        $copy = New-Tracked 'agents-gone'
        $f = New-AgentFile $copy 'p/agents/ephemeral.agent.md' 'ephemeral'
        $idx2 = Get-AgentDefinitionIndex -SearchRoots @($copy)
        Remove-Item -LiteralPath $copy -Recurse -Force
        Find-AgentDefinition -Name 'ephemeral' -Index $idx2 | Should -Be $f
        Find-AgentDefinition -Name 'deneb-reviewer' -Index $idx | Should -Be $script:DenebAgent
    }
    It 'Resolve-RolePersona renders a stem.agent.md agent instead of warning it is missing' {
        $w = @()
        $p = Resolve-RolePersona -Role @{ name='r'; agent='reports:deneb-reviewer'; standards=@('FALLBACK') } `
                                 -SearchRoots $script:Roots -WarningVariable w -WarningAction SilentlyContinue
        $p | Should -Match 'careful reviewer'
        $p | Should -Not -Match 'FALLBACK'
        @($w).Count | Should -Be 0
    }
    It 'Resolve-RolePersona still warns and falls back for an agent that is not installed' {
        $w = @()
        $p = Resolve-RolePersona -Role @{ name='r'; agent='ghost'; standards=@('FALLBACK') } `
                                 -SearchRoots $script:Roots -WarningVariable w -WarningAction SilentlyContinue
        $p | Should -Match 'FALLBACK'
        (@($w) -join ' ') | Should -Match "agent 'ghost'"
    }
}

Describe 'Find-FilesPruned never enters an excluded directory (#609)' {
    It 'finds files outside the excluded directories and none inside them' {
        $root = New-Tracked 'prune-basic'
        New-Item -ItemType Directory -Path "$root/keep/sub", "$root/node_modules/pkg", "$root/build/out" -Force | Out-Null
        foreach ($f in 'keep/a.md', 'keep/sub/b.md', 'node_modules/pkg/c.md', 'build/out/d.md') { Set-Content -LiteralPath (Join-Path $root $f) -Value 'x' }
        $names = @(Find-FilesPruned -Root $root -Filter '*.md') | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object
        $names | Should -Be @('a.md', 'b.md')
    }
    It 'walks an excluded tree in a fraction of the time it takes to walk it unpruned' {
        # The excluded tree is the whole cost: 1500 directories. Pruned, it is one skipped name;
        # unpruned it is 1500 directory reads. Same tree, same machine, same load — a ratio.
        $root = New-Tracked 'prune-cost'
        New-Item -ItemType Directory -Path "$root/keep" -Force | Out-Null
        Set-Content -LiteralPath "$root/keep/hit.md" -Value 'x'
        1..1500 | ForEach-Object { New-Item -ItemType Directory -Path "$root/node_modules/p$_" -Force | Out-Null }
        # Best of three per side: a scheduling hiccup on a loaded CI runner inflates one sample,
        # not the minimum, so the ratio measures the walk and not the machine.
        $pruned = [double]::MaxValue; $unpruned = [double]::MaxValue
        foreach ($i in 1..3) {
            $pruned   = [math]::Min($pruned,   (Measure-Command { $a = @(Find-FilesPruned -Root $root -Filter '*.md') }).TotalMilliseconds)
            $unpruned = [math]::Min($unpruned, (Measure-Command { $b = @(Find-FilesPruned -Root $root -Filter '*.md' -ExcludeDirs @()) }).TotalMilliseconds)
        }
        @($a).Count | Should -Be 1
        @($b).Count | Should -Be 1
        $pruned | Should -BeLessThan ($unpruned / 3)
    }
    It 'stops at an expired deadline and says the result is partial' {
        $root = New-Tracked 'prune-deadline'
        New-Item -ItemType Directory -Path "$root/a" -Force | Out-Null
        Set-Content -LiteralPath "$root/a/x.md" -Value 'x'
        $w = @()
        $r = @(Find-FilesPruned -Root $root -Filter '*.md' -Deadline ([datetime]::UtcNow.AddSeconds(-5)) -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 0
        (@($w) -join ' ') | Should -Match 'PARTIAL'
    }
    It 'does not descend below -MaxDepth' {
        $root = New-Tracked 'prune-depth'
        New-Item -ItemType Directory -Path "$root/a/b/c" -Force | Out-Null
        Set-Content -LiteralPath "$root/a/b/c/deep.md" -Value 'x'
        @(Find-FilesPruned -Root $root -Filter '*.md' -MaxDepth 2).Count | Should -Be 0
        @(Find-FilesPruned -Root $root -Filter '*.md' -MaxDepth 3).Count | Should -Be 1
    }
    It 'yields nothing for a root that does not exist' {
        @(Find-FilesPruned -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-dir-zz') -Filter '*.md').Count | Should -Be 0
    }
    It 'returns files in the same order Get-ChildItem -Recurse does' {
        $root = New-Tracked 'prune-order'
        foreach ($rel in 'b', 'a/z', 'a/y', 'c/d/e') { New-Item -ItemType Directory -Path (Join-Path $root $rel) -Force | Out-Null }
        foreach ($f in 'top.md', 'a/one.md', 'a/y/two.md', 'a/z/three.md', 'b/four.md', 'c/d/e/five.md') { Set-Content -LiteralPath (Join-Path $root $f) -Value 'x' }
        $expected = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md') | ForEach-Object { $_.FullName }
        @(Find-FilesPruned -Root $root -Filter '*.md') | Should -Be $expected
    }
    It 'does not follow a junction (no cycles, same as Get-ChildItem -Recurse)' -Skip:(-not $IsWindows) {
        $root = New-Tracked 'prune-junction'
        New-Item -ItemType Directory -Path "$root/real" -Force | Out-Null
        Set-Content -LiteralPath "$root/real/x.md" -Value 'x'
        New-Item -ItemType Junction -Path "$root/loop" -Target $root | Out-Null
        @(Find-FilesPruned -Root $root -Filter '*.md').Count | Should -Be 1
    }
}

Describe 'Get-SkillInventory (#609)' {
    BeforeAll {
        $script:Inv = Join-Path $script:Scripts 'Get-SkillInventory.ps1'
        function New-Skill {
            param([string]$Root, [string]$RelDir, [string]$Name, [string]$Description)
            $d = Join-Path $Root $RelDir
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'SKILL.md') -Encoding utf8 -Value "---`nname: $Name`ndescription: $Description`n---`nBody"
        }
    }

    It 'ignores SKILL.md files under excluded directories' {
        $root = New-Tracked 'inv-excl'
        New-Skill $root '.claude/skills/p/real' 'real' 'A real skill. Use when testing.'
        New-Skill $root 'node_modules/pkg/skills/vendored' 'vendored' 'Vendored. Use when testing.'
        New-Skill $root 'dist/skills/built' 'built' 'Built. Use when testing.'
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0
        @($r.skills.name) | Should -Be @('real')
    }
    It 'still finds skills when the ROOT itself sits below a directory named like an excluded one' {
        # The old post-filter matched /build/ anywhere in the FULL path, so a checkout under
        # .../build/repo scanned as empty. Only names BELOW the root are excluded now.
        $outer = New-Tracked 'inv-outer'
        $root  = Join-Path $outer 'build/repo'
        New-Skill $root '.claude/skills/p/real' 'real' 'A real skill. Use when testing.'
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0
        @($r.skills.name) | Should -Be @('real')
    }
    It 'gives up on a scope whose walk exceeds -TimeoutSeconds, warning that the inventory is partial' {
        $root = New-Tracked 'inv-timeout'
        New-Skill $root '.claude/skills/p/real' 'real' 'A real skill. Use when testing.'
        $w = @()
        # 0.0001 s: the budget is spent before the first directory is read.
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0.0001 -WarningVariable w -WarningAction SilentlyContinue
        @($r.skills).Count | Should -Be 0
        (@($w) -join ' ') | Should -Match 'PARTIAL'
    }
    It 'Resolve-SkillInventory passes its budget through (the config and roles callers are bounded)' {
        $root = New-Tracked 'inv-resolve'
        New-Skill $root '.claude/skills/p/real' 'real' 'A real skill. Use when testing.'
        @(Resolve-SkillInventory -Root $root -Scope project) | Should -Contain 'real'
        @(Resolve-SkillInventory -Root $root -Scope project -TimeoutSeconds 0.0001 -WarningAction SilentlyContinue).Count | Should -Be 0
    }
    It 'returns the same near-duplicate pairs as the naive pairwise algorithm' {
        $root = New-Tracked 'inv-overlap'
        $descs = [ordered]@{
            'a1' = 'alpha bravo charlie delta echo foxtrot golf hotel'
            'a2' = 'alpha bravo charlie delta echo foxtrot golf india'   # 7/9 with a1
            'a3' = 'alpha bravo charlie delta'                            # 4/8 = 0.5 with a1: exactly on the threshold
            'a4' = 'alpha bravo charlie'                                  # 3/8 = 0.375 with a1: below
            'b1' = 'kilo lima mike november oscar papa'
            'b2' = 'kilo lima mike november oscar quebec romeo'           # 5/8
            'c1' = 'zulu'                                                 # fewer than 4 letters per word are dropped, this is one keyword
            'c2' = 'yankee xray whiskey victor uniform tango sierra'
            'd1' = 'the and for use'                                      # all stop words / short: no keywords at all
        }
        foreach ($k in $descs.Keys) { New-Skill $root ".claude/skills/p/$k" $k $descs[$k] }
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0

        # Independent reference: the original pairwise algorithm, written out naively.
        $stop = @('the','and','for','use','when','with','that','this','from','into','your','skill','user','asks','want','wants','need','needs','a','an','to','of','in','on','or','is','it','be','are','you','can','via','not','but','has','had','als','del','los','las','una','uno','por','con','que','para','como')
        $kw = @{}
        foreach ($k in $descs.Keys) {
            $kw[$k] = @(($descs[$k].ToLower() -split '[^a-z0-9]+') | Where-Object { $_.Length -gt 3 -and $stop -notcontains $_ } | Sort-Object -Unique)
        }
        $keys = @($r.skills | ForEach-Object { $_.name })
        $expected = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $keys.Count; $i++) {
            for ($j = $i + 1; $j -lt $keys.Count; $j++) {
                $x = $kw[$keys[$i]]; $y = $kw[$keys[$j]]
                if ($x.Count -eq 0 -or $y.Count -eq 0) { continue }
                $inter = @($x | Where-Object { $y -contains $_ }).Count
                $union = (@($x) + @($y) | Sort-Object -Unique).Count
                $jac = [math]::Round($inter / $union, 3)
                if ($jac -ge 0.5) { $expected.Add("$($keys[$i])|$($keys[$j])|$jac") }
            }
        }
        $actual = @($r.overlaps | ForEach-Object { "$($_.a)|$($_.b)|$($_.jaccard)" })
        $expected.Count | Should -BeGreaterThan 2      # the fixture must actually exercise the pass
        $actual | Should -Be @($expected)
    }
    It 'never pairs a skill that has no keywords, even at threshold 0' {
        $root = New-Tracked 'inv-empty'
        New-Skill $root '.claude/skills/p/full' 'full' 'alpha bravo charlie delta'
        New-Skill $root '.claude/skills/p/zempty' 'zempty' 'the and for use'
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0 -OverlapThreshold 0
        @($r.overlaps).Count | Should -Be 0
    }
    It 'flags a high-overlap pair and not a low-overlap one' {
        $root = New-Tracked 'inv-edge'
        New-Skill $root '.claude/skills/p/e1' 'e1' 'alpha bravo charlie delta'
        New-Skill $root '.claude/skills/p/e2' 'e2' 'alpha bravo echo foxtrot'   # 2 shared / 6 union = 0.333
        New-Skill $root '.claude/skills/p/e3' 'e3' 'alpha bravo charlie golf'   # 3 shared / 5 union = 0.6
        $r = & $script:Inv -Root $root -Scope project -TimeoutSeconds 0
        $pairs = @($r.overlaps | ForEach-Object { "$($_.a)|$($_.b)" })
        $pairs | Should -Contain 'e1|e3'
        $pairs | Should -Not -Contain 'e1|e2'
    }
}

Describe 'Expert-Roles.ps1 -List (CLI, #609 / #469)' {
    BeforeAll {
        # A hermetic project + home: the run must not depend on (or touch) the developer's own
        # ~/.claude or ~/.agentic-board.
        $script:FakeHome = New-Tracked 'roles-home'
        $script:Repo = New-Tracked 'roles-repo'
        Push-Location $script:Repo
        try {
            & git init -q . 2>&1 | Out-Null
            New-Item -ItemType Directory -Path '.agentic-board' -Force | Out-Null
            Set-Content -LiteralPath '.agentic-board/roles.json' -Encoding utf8 -Value (@{
                version = 1
                roles = @(
                    @{ name = 'has-agent';     keywords = @('zebra');  skills = @('zzz'); agent = 'fixture-reviewer' },
                    @{ name = 'missing-agent'; keywords = @('giraffe'); skills = @('zzz'); agent = 'ghost-agent' }
                )
            } | ConvertTo-Json -Depth 6)
        } finally { Pop-Location }
        New-AgentFile $script:Repo '.claude/agents/fixture-reviewer.agent.md' 'fixture-reviewer' | Out-Null

        $prevHome = $env:HOME; $prevProf = $env:USERPROFILE
        $env:HOME = $script:FakeHome; $env:USERPROFILE = $script:FakeHome
        Push-Location $script:Repo
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $script:Out = & pwsh -NoProfile -File (Join-Path $script:Scripts 'Expert-Roles.ps1') -List 2>&1 | Out-String
            $script:Elapsed = $sw.Elapsed.TotalSeconds
        } finally {
            Pop-Location
            $env:HOME = $prevHome; $env:USERPROFILE = $prevProf
        }
    }

    It 'tells the user it is scanning BEFORE it prints the table' {
        $iScan  = $script:Out.IndexOf('Scanning installed skills')
        $iTable = $script:Out.IndexOf('=== /board expert roles ===')
        $iScan  | Should -BeGreaterOrEqual 0
        $iTable | Should -BeGreaterThan $iScan
    }
    It 'prints the catalog' {
        $script:Out | Should -Match 'has-agent'
        $script:Out | Should -Match 'powerbi-report'
    }
    It 'marks a role whose agent resolves (a stem.agent.md definition) as ok' {
        $script:Out | Should -Match '(?m)^\s+has-agent\b.*\bok\s*$'
    }
    It 'marks a role whose agent is not installed as MISSING, and says which one' {
        $script:Out | Should -Match '(?m)^\s+missing-agent\b.*\bMISSING\s*$'
        $script:Out | Should -Match "role 'missing-agent' names agent 'ghost-agent'"
    }
    It 'shows a dash, not a verdict, for a role with no agent' {
        $script:Out | Should -Match '(?m)^\s+powerbi-report\b.*\s-\s*$'
    }
    It 'finishes in seconds on a small tree' {
        $script:Elapsed | Should -BeLessThan 60
    }
}
