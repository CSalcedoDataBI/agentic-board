#Requires -Modules Pester
<#  Skills-audit noise (#462): the overlap pass must not report a skill against a COPY of itself,
    and the "Triggers" lint must accept the way this repo's own skills write it ("Triggers — a, b").

    Every fixture is a temp directory; USERPROFILE is pointed at a fake home for the run, so the
    real ~/.claude is never read. The tests drive the real Get-SkillInventory.ps1 and
    Invoke-SkillAudit.ps1. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Engine  = Join-Path $script:Scripts 'Get-SkillInventory.ps1'
    $script:Audit   = Join-Path $script:Scripts 'Invoke-SkillAudit.ps1'
    $script:Tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ('skillcopies-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:SavedProfile = $env:USERPROFILE
    $script:Emdash = [string][char]0x2014
    $script:Endash = [string][char]0x2013

    function New-Fixture {
        # A fresh project root + fake home per test; returns both.
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
    # The three usual places one skill shows up: the repo tree, a worktree of it, the installed plugin cache.
    function New-Copies {
        param($Fx, [string]$Name, [string]$Description, [string]$CacheDescription = $Description)
        New-Skill $Fx.Root "plugins/tool/skills/$Name" $Name $Description
        New-Skill $Fx.Root ".claude/worktrees/wt1/plugins/tool/skills/$Name" $Name $Description
        New-Skill $Fx.Home ".claude/plugins/cache/tool/skills/$Name" $Name $CacheDescription
    }
    function Invoke-Inv {
        param($Fx)
        $env:USERPROFILE = $Fx.Home
        try { & $script:Engine -Root $Fx.Root -Scope all -TimeoutSeconds 0 } finally { $env:USERPROFILE = $script:SavedProfile }
    }
    function Invoke-Aud {
        param($Fx, [string]$Name)
        $env:USERPROFILE = $Fx.Home
        try {
            if ($Name) { & $script:Audit -Root $Fx.Root -Scope all -CurrentRepo 'me/repo' -Name $Name }
            else       { & $script:Audit -Root $Fx.Root -Scope all -CurrentRepo 'me/repo' }
        } finally { $env:USERPROFILE = $script:SavedProfile }
    }
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    if ($script:Tmp -and (Test-Path $script:Tmp)) { Remove-Item $script:Tmp -Recurse -Force }
}

Describe 'copies of one skill are not reported against each other (#462)' {
    It 'three identical copies of one skill produce no overlap and no finding, and say they were collapsed' {
        $fx = New-Fixture 'same'
        New-Copies $fx 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        $inv = Invoke-Inv $fx
        @($inv.skills).Count | Should -Be 3
        @($inv.overlaps).Count | Should -Be 0
        $inv.summary.overlaps | Should -Be 0
        $inv.summary.collapsedCopies | Should -Be 2

        $aud = Invoke-Aud $fx
        @($aud.findings | Where-Object type -in 'near-duplicate', 'divergent-copy').Count | Should -Be 0
        $aud.summary.copiesCollapsed | Should -Be 2
    }
    It 'copies whose descriptions differ only in whitespace and case are still one skill' {
        $fx = New-Fixture 'ws'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'reconciles   LEDGER entries  against bank statements.'
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 0
        $inv.summary.collapsedCopies | Should -Be 1
    }
    It 'copies with an empty description collapse and are not a divergence' {
        $fx = New-Fixture 'empty'
        New-Skill $fx.Root 'plugins/tool/skills/blank-one' 'blank-one' ''
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/blank-one' 'blank-one' ''
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 0
        $inv.summary.collapsedCopies | Should -Be 1
    }
    It 'a genuine overlap between two DIFFERENT skills is still reported once, saying how many copies it stands for' {
        $fx = New-Fixture 'genuine'
        New-Copies $fx 'report-builder' 'Generate quarterly revenue reports from spreadsheets for financial dashboards.'
        New-Copies $fx 'revenue-reporter' 'Build quarterly revenue reports from spreadsheets for financial dashboards.'
        $inv = Invoke-Inv $fx
        @($inv.skills).Count | Should -Be 6
        @($inv.overlaps).Count | Should -Be 1
        $o = $inv.overlaps[0]
        $o.kind | Should -Be 'near-duplicate'
        $o.aCopies | Should -Be 3
        $o.bCopies | Should -Be 3
        $inv.summary.collapsedCopies | Should -Be 4

        $aud = Invoke-Aud $fx
        $nd = @($aud.findings | Where-Object type -eq 'near-duplicate')
        $nd.Count | Should -Be 1
        $nd[0].detail | Should -Match 'identical copies'
    }
    It 'two different skills with the very same description are NOT treated as copies' {
        $fx = New-Fixture 'twins'
        New-Skill $fx.Root '.claude/skills/p/alpha-skill' 'alpha-skill' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Root '.claude/skills/p/beta-skill' 'beta-skill' 'Reconciles ledger entries against bank statements each month.'
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 1
        $inv.overlaps[0].kind | Should -Be 'near-duplicate'
        $inv.overlaps[0].jaccard | Should -Be 1
        $inv.summary.collapsedCopies | Should -Be 0
    }
    It 'the representative of a group of copies is the most local one, so the finding is attributed to it' {
        $fx = New-Fixture 'rep'
        New-Copies $fx 'report-builder' 'Generate quarterly revenue reports from spreadsheets for financial dashboards.'
        New-Skill $fx.Root '.claude/skills/p/revenue-reporter' 'revenue-reporter' 'Build quarterly revenue reports from spreadsheets for financial dashboards.'
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 1
        $o = $inv.overlaps[0]
        $names = @($o.a, $o.b)
        $names | Should -Contain 'report-builder'             # project scope wins over the cache copy 'tool:report-builder'
        $names | Should -Not -Contain 'tool:report-builder'
        $repPath = @($o.aPath, $o.bPath) | Where-Object { $_ -match 'report-builder' }
        $repPath | Should -Not -Match '/home/'                # not the fake-home plugin cache copy
        $repPath | Should -Not -Match 'worktrees'             # the tree copy, not the worktree copy
    }
    It 'the audit summary and the inventory summary agree on the number of overlaps' {
        $fx = New-Fixture 'consistent'
        New-Copies $fx 'report-builder' 'Generate quarterly revenue reports from spreadsheets for financial dashboards.'
        New-Copies $fx 'revenue-reporter' 'Build quarterly revenue reports from spreadsheets for financial dashboards.'
        New-Copies $fx 'ledger-tool' 'Reconciles ledger entries against bank statements each month.' 'Totally unrelated text about gardening tomatoes outdoors.'
        $inv = Invoke-Inv $fx
        $aud = Invoke-Aud $fx
        $pairs = @($aud.findings | Where-Object type -in 'near-duplicate', 'divergent-copy').Count
        $pairs | Should -Be $inv.summary.overlaps
        $pairs | Should -Be 2
    }
}

Describe 'copies of one name with DIFFERENT descriptions stay visible as a stale copy (#462)' {
    It 'is reported as divergent-copy even when the descriptions share no keywords' {
        $fx = New-Fixture 'stale'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'Totally unrelated text about gardening tomatoes outdoors.'
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 1
        $inv.overlaps[0].kind | Should -Be 'divergent-copy'
        $inv.overlaps[0].jaccard | Should -BeLessThan 0.5

        $aud = Invoke-Aud $fx
        $f = @($aud.findings | Where-Object type -eq 'divergent-copy')
        $f.Count | Should -Be 1
        $f[0].detail | Should -Match 'different descriptions'
        $f[0].detail | Should -Match 'project vs plugin'
        # A finding may be filed later: it names scopes, never local paths.
        $f[0].detail | Should -Not -Match ([regex]::Escape($script:Tmp))
        @($aud.findings | Where-Object type -eq 'near-duplicate').Count | Should -Be 0
    }
    It 'a stale copy that still overlaps heavily is a divergent-copy, not also a near-duplicate' {
        $fx = New-Fixture 'stale-close'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements every quarter.'
        $inv = Invoke-Inv $fx
        @($inv.overlaps).Count | Should -Be 1
        $inv.overlaps[0].kind | Should -Be 'divergent-copy'
    }
    It 'three different descriptions of one name give two pairs against the primary, not every pairing' {
        $fx = New-Fixture 'stale3'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Root '.claude/worktrees/wt1/plugins/tool/skills/ledger-tool' 'ledger-tool' 'Totally unrelated text about gardening tomatoes outdoors.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'Another wording entirely about sailing boats offshore.'
        $inv = Invoke-Inv $fx
        $div = @($inv.overlaps | Where-Object kind -eq 'divergent-copy')
        $div.Count | Should -Be 2
        @($div.aPath | Sort-Object -Unique).Count | Should -Be 1
        $div[0].aPath | Should -Not -Match 'worktrees'      # the primary is the real tree, not a worktree copy of it
    }
    It 'the -Name filter still surfaces the stale copy of that skill' {
        $fx = New-Fixture 'stale-name'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'Totally unrelated text about gardening tomatoes outdoors.'
        $aud = Invoke-Aud $fx 'ledger-tool'
        @($aud.findings | Where-Object type -eq 'divergent-copy').Count | Should -Be 1
    }
}

Describe 'auditing one specific copy still finds its pair (#462)' {
    It '-Name with the namespaced (non-primary) copy still yields the divergent-copy finding, phrased from that copy' {
        $fx = New-Fixture 'name-b'
        New-Skill $fx.Root 'plugins/tool/skills/ledger-tool' 'ledger-tool' 'Reconciles ledger entries against bank statements each month.'
        New-Skill $fx.Home '.claude/plugins/cache/tool/skills/ledger-tool' 'ledger-tool' 'Totally unrelated text about gardening tomatoes outdoors.'
        $aud = Invoke-Aud $fx 'tool:ledger-tool'
        $f = @($aud.findings | Where-Object type -eq 'divergent-copy')
        $f.Count | Should -Be 1
        $f[0].skill | Should -Be 'tool:ledger-tool'
        $f[0].detail | Should -Match 'plugin vs project'
    }
    It '-Name with a copy folded into the first side of a near-duplicate still yields the finding' {
        $fx = New-Fixture 'name-a'
        New-Copies $fx 'report-builder' 'Generate quarterly revenue reports from spreadsheets for financial dashboards.'
        # Personal scope is walked after project scope, so report-builder is deterministically the first side.
        New-Skill $fx.Home '.claude/skills/revenue-reporter' 'revenue-reporter' 'Build quarterly revenue reports from spreadsheets for financial dashboards.'
        $aud = Invoke-Aud $fx 'tool:report-builder'
        @($aud.findings | Where-Object type -eq 'near-duplicate').Count | Should -Be 1
    }
    It 'the same skill under two plugin namespaces (a cache and a marketplaces clone name them differently) is one skill' {
        $fx = New-Fixture 'ns'
        New-Skill $fx.Home '.claude/plugins/cache/alpha/skills/review' 'review' 'Reviews pull requests for security issues. Use when auditing PRs.'
        New-Skill $fx.Home '.claude/plugins/marketplaces/beta/skills/review' 'review' 'Reviews pull requests for security issues. Use when auditing PRs.'
        $inv = Invoke-Inv $fx
        @($inv.skills).Count | Should -Be 2
        @($inv.overlaps).Count | Should -Be 0
        $inv.summary.collapsedCopies | Should -Be 1
    }
}

Describe 'the Triggers lint accepts the way this repo writes it (#462)' {
    BeforeAll {
        $script:Fx = New-Fixture 'triggers'
        $script:Cases = [ordered]@{
            'trig-emdash-space'   = @("Formats things. Triggers $($script:Emdash) alpha, beta.", $true)
            'trig-emdash-tight'   = @("Formats things. Triggers$($script:Emdash) alpha, beta.", $true)
            'trig-endash-space'   = @("Formats things. Triggers $($script:Endash) alpha, beta.", $true)
            'trig-colon'          = @('Formats things. Triggers: alpha, beta.', $true)
            'trig-colon-space'    = @('Formats things. Triggers : alpha, beta.', $true)
            'trig-hyphen-space'   = @('Formats things. Triggers - alpha, beta.', $true)
            'trig-singular'       = @("Formats things. Trigger $($script:Emdash) alpha.", $true)
            'prose-happen'        = @('Formats things. Triggers happen when nothing calls it.', $false)
            'prose-hyphenated'    = @('Formats things. A trigger-happy helper.', $false)
            'prose-are'           = @('Formats things. The triggers are many.', $false)
            'prose-prefix'        = @('Formats things. Retriggers: none.', $false)
        }
        foreach ($k in $script:Cases.Keys) { New-Skill $script:Fx.Root ".claude/skills/p/$k" $k $script:Cases[$k][0] }
        $script:Inv = Invoke-Inv $script:Fx
    }
    It '<_> is classified as expected' -ForEach @(
        'trig-emdash-space', 'trig-emdash-tight', 'trig-endash-space', 'trig-colon', 'trig-colon-space',
        'trig-hyphen-space', 'trig-singular', 'prose-happen', 'prose-hyphenated', 'prose-are', 'prose-prefix'
    ) {
        $k = $_
        $rec = $script:Inv.skills | Where-Object name -eq $k
        $rec | Should -Not -BeNullOrEmpty
        $rec.lint.hasTriggers | Should -Be $script:Cases[$k][1]
    }
    It 'the audit raises no-triggers for the prose cases and not for the real clauses' {
        $aud = Invoke-Aud $script:Fx
        $flagged = @($aud.findings | Where-Object type -eq 'no-triggers').skill
        foreach ($k in $script:Cases.Keys) {
            if ($script:Cases[$k][1]) { $flagged | Should -Not -Contain $k } else { $flagged | Should -Contain $k }
        }
    }
    It 'the other Use-when phrasings are unchanged' {
        $fx = New-Fixture 'usewhen'
        New-Skill $fx.Root '.claude/skills/p/uw' 'uw' 'Formats things. Use when the report needs formatting.'
        New-Skill $fx.Root '.claude/skills/p/none' 'none' 'Formats things somehow.'
        $inv = Invoke-Inv $fx
        ($inv.skills | Where-Object name -eq 'uw').lint.hasTriggers | Should -BeTrue
        ($inv.skills | Where-Object name -eq 'none').lint.hasTriggers | Should -BeFalse
    }
}
