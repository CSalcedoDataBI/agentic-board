#Requires -Modules Pester
<#  Tests for who decides the merge at /board work step 5d/5e (#797).

    A repo can hand the merge decision to its own expert agent - by its files (an approved
    FICHA.md + .claude/agents/experto.md) or by `mergeAuthority` in .agentic-board/config.json.
    Detection must be deterministic, and a repo that declares nothing must keep today's flow:
    the user confirms every merge. A declared expert also makes grouped PRs the default, while a
    recorded grouping answer still wins. The end-to-end cases run the real script in a throw-away
    git repo with NO token reachable, like the #662/#681 tests. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    $script:Plugin = Join-Path $PSScriptRoot '..' '..' 'plugins' 'agentic-board'

    function New-ThrowawayRepo([string]$Name) {
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        git -C $path init -q 2>&1 | Out-Null
        $path
    }
    function Add-Expert([string]$Root) {
        $dir = Join-Path $Root '.claude' 'agents'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'experto.md') -Value "---`nname: experto`n---`nReviews and merges." -Encoding UTF8
    }
    function Add-Ficha([string]$Root, [string]$Body) {
        Set-Content -LiteralPath (Join-Path $Root 'FICHA.md') -Value $Body -Encoding UTF8
    }
    # Commit everything and point origin/main at it: the default branch Board-Work reads the
    # declaration from (#797). Without it, the throw-away repo has no default branch to trust.
    function Publish-Main([string]$Root) {
        git -C $Root add -A 2>&1 | Out-Null
        git -C $Root -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base 2>&1 | Out-Null
        git -C $Root update-ref refs/remotes/origin/main HEAD 2>&1 | Out-Null
    }
    function New-NorteRepo([string]$Name) {
        $root = New-ThrowawayRepo $Name
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        Publish-Main $root
        $root
    }
    function Invoke-BoardWork([string]$Dir, [hashtable]$Params) {
        $saved = $env:GH_TOKEN
        $env:GH_TOKEN = ''
        Push-Location $Dir
        try {
            # Reset first: a path that returned without `exit` would otherwise report whatever the
            # last git call in the fixture left behind.
            $global:LASTEXITCODE = -1
            $out = & $script:Script @Params -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 6>&1 2>&1 | Out-String
            $code = $LASTEXITCODE
            [pscustomobject]@{ out = $out; code = $code }
        } finally { Pop-Location; $env:GH_TOKEN = $saved }
    }
}

Describe 'Get-MergeAuthority: deterministic detection' {
    It 'a repo that declares nothing -> user, from the default (today''s flow)' {
        $root = New-ThrowawayRepo 'nothing'
        $a = Get-MergeAuthority -Config (Get-BoardConfigDefaults) -Root $root
        $a.authority | Should -Be 'user'
        $a.source    | Should -Be 'default'
        $a.warning   | Should -BeNullOrEmpty
    }
    It 'no root at all (outside a repo) -> user, from the default' {
        (Get-MergeAuthority -Config $null -Root '').authority | Should -Be 'user'
    }
    It 'an approved FICHA.md + experto.md -> expert, from the files' {
        $root = New-ThrowawayRepo 'norte'
        Add-Expert $root
        Add-Ficha $root "# Ficha`n`nAprobada: 2026-10-01`n"
        $a = Get-MergeAuthority -Config (Get-BoardConfigDefaults) -Root $root
        $a.authority     | Should -Be 'expert'
        $a.source        | Should -Be 'files'
        $a.fichaApproved | Should -Be '2026-10-01'
    }
    It 'reads the approval line in bold or as a list item too' {
        foreach ($line in @('**Aprobada:** 2026-10-02', '- Aprobada: 2026-10-02', '> Aprobada: 2026-10-02')) {
            $root = New-ThrowawayRepo ('fmt' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root "# Ficha`n$line`n"
            (Get-MergeAuthority -Config $null -Root $root).authority | Should -Be 'expert' -Because "'$line' is an approval line"
        }
    }
    It 'a FICHA.md with no approval date is a draft -> user, and it says why' {
        $root = New-ThrowawayRepo 'draft'
        Add-Expert $root
        Add-Ficha $root "# Ficha`n`nAprobada: pendiente`n"
        $a = Get-MergeAuthority -Config $null -Root $root
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'draft'
    }
    It 'an approved FICHA.md with no expert agent -> user' {
        $root = New-ThrowawayRepo 'noagent'
        Add-Ficha $root "Aprobada: 2026-10-01"
        (Get-MergeAuthority -Config $null -Root $root).authority | Should -Be 'user'
    }
    It 'an expert agent with no FICHA.md -> user (the plan it merges against is missing)' {
        $root = New-ThrowawayRepo 'noficha'
        Add-Expert $root
        (Get-MergeAuthority -Config $null -Root $root).authority | Should -Be 'user'
    }
    It 'config mergeAuthority=expert + experto.md -> expert, from the config (no FICHA needed)' {
        $root = New-ThrowawayRepo 'cfgexpert'
        Add-Expert $root
        $a = Get-MergeAuthority -Config @{ mergeAuthority = 'expert' } -Root $root
        $a.authority | Should -Be 'expert'
        $a.source    | Should -Be 'config'
    }
    It 'config mergeAuthority=expert with NO agent file -> user, with a warning' {
        $root = New-ThrowawayRepo 'cfgnoagent'
        $a = Get-MergeAuthority -Config @{ mergeAuthority = 'expert' } -Root $root
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'does not exist'
    }
    It 'config mergeAuthority=user is an opt-out that beats the files' {
        $root = New-ThrowawayRepo 'optout'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        $a = Get-MergeAuthority -Config @{ mergeAuthority = 'User' } -Root $root
        $a.authority | Should -Be 'user'
        $a.source    | Should -Be 'config'
    }
    It 'an unrecognised mergeAuthority fails CLOSED to user, even over an approved FICHA' {
        $root = New-ThrowawayRepo 'garbage'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        foreach ($garbage in @('maybe', 'none', 'usr', 42, $false, $true)) {
            $a = Get-MergeAuthority -Config @{ mergeAuthority = $garbage } -Root $root
            $a.authority | Should -Be 'user' -Because "'$garbage' may be an attempted opt-out, and merging cannot be undone"
            $a.warning   | Should -Match 'user confirms'
        }
    }
    It 'a config.json that cannot be read fails CLOSED to user, even over an approved FICHA' {
        $root = New-ThrowawayRepo 'unreadable'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        $a = Get-MergeAuthority -Config (Get-BoardConfigDefaults) -Root $root -ConfigUnreadable
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'cannot be read'
    }
    It 'reads an approval line wrapped in underscore emphasis' {
        foreach ($line in @('_Aprobada: 2026-10-02_', '__Aprobada:__ 2026-10-02')) {
            $root = New-ThrowawayRepo ('und' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root $line
            (Get-MergeAuthority -Config $null -Root $root).fichaApproved | Should -Be '2026-10-02' -Because "'$line' is an approval line"
        }
    }
    It 'the same inputs give the same answer every time' {
        $root = New-ThrowawayRepo 'repeat'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        $answers = 1..3 | ForEach-Object { (Get-MergeAuthority -Config $null -Root $root).authority }
        @($answers | Select-Object -Unique) | Should -Be @('expert')
    }
}

Describe 'Get-MergeAuthority -GitRef: the PR under review cannot grant itself the merge' {
    It 'files committed on the default branch -> expert' {
        $root = New-NorteRepo 'ref-main'
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'expert'
        $a.source    | Should -Be 'files'
    }
    It 'a PR branch that ADDS an approved FICHA.md + experto.md -> user' {
        $root = New-ThrowawayRepo 'ref-attack'
        Publish-Main $root
        git -C $root checkout -q -b issue-1-grant 2>&1 | Out-Null
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        git -C $root add -A 2>&1 | Out-Null
        git -C $root -c user.name=t -c user.email=t@example.com commit -q -m grant 2>&1 | Out-Null
        (Get-MergeAuthority -Config $null -Root $root).authority | Should -Be 'expert' -Because 'on disk the branch has the files'
        (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main').authority | Should -Be 'user' -Because 'the default branch never approved them'
    }
    It 'a PR branch that drafts the committed FICHA does not revoke it either (the rules in force are main''s)' {
        $root = New-NorteRepo 'ref-edit'
        Add-Ficha $root "Aprobada: pendiente"
        (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main').authority | Should -Be 'expert'
    }
    It 'mergeAuthority=expert only in the local config -> user, with a warning' {
        $root = New-ThrowawayRepo 'ref-localexpert'
        Add-Expert $root
        Publish-Main $root
        $a = Get-MergeAuthority -Config @{ mergeAuthority = 'expert' } -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'once it is committed'
    }
    It 'mergeAuthority=expert committed on the default branch -> expert, from the config' {
        $root = New-ThrowawayRepo 'ref-cfgexpert'
        Add-Expert $root
        New-Item -ItemType Directory -Path (Join-Path $root '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root '.agentic-board' 'config.json') -Value '{ "mergeAuthority": "expert" }' -Encoding UTF8
        Publish-Main $root
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'expert'
        $a.source    | Should -Be 'config'
    }
    It 'a local opt-out wins over a committed grant' {
        $root = New-NorteRepo 'ref-optout'
        (Get-MergeAuthority -Config @{ mergeAuthority = 'user' } -Root $root -GitRef 'origin/main').authority | Should -Be 'user'
    }
    It 'a committed opt-out or unreadable committed config wins over the files' {
        foreach ($body in @('{ "mergeAuthority": "user" }', '{ "mergeAuthority": "none" }', '{ not json')) {
            $root = New-ThrowawayRepo ('ref-basecfg' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root "Aprobada: 2026-10-01"
            New-Item -ItemType Directory -Path (Join-Path $root '.agentic-board') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.agentic-board' 'config.json') -Value $body -Encoding UTF8
            Publish-Main $root
            (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main').authority | Should -Be 'user' -Because "committed config '$body'"
        }
    }
    It 'an EMPTY experto.md is no expert, on disk and on the ref alike' {
        $root = New-ThrowawayRepo 'ref-empty'
        New-Item -ItemType Directory -Path (Join-Path $root '.claude' 'agents') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root '.claude' 'agents' 'experto.md') -Force | Out-Null
        Add-Ficha $root "Aprobada: 2026-10-01"
        Publish-Main $root
        (Get-MergeAuthority -Config $null -Root $root).authority                       | Should -Be 'user'
        (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main').authority | Should -Be 'user'
    }
    It 'an unparseable committed config says so, not that a mergeAuthority value is bad' {
        $root = New-ThrowawayRepo 'ref-badjson'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        New-Item -ItemType Directory -Path (Join-Path $root '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root '.agentic-board' 'config.json') -Value '[1, 2]' -Encoding UTF8
        Publish-Main $root
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'not a readable JSON object'
    }
    It 'reads a real, multi-line FICHA.md from the ref (heading, prose, bold approval on a later line)' {
        foreach ($line in @('Aprobada: 2026-10-02', '**Aprobada:** 2026-10-02', '- Aprobada: 2026-10-02')) {
            $root = New-ThrowawayRepo ('ref-multi' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root "# Ficha de la herramienta`n`nQue hace y que no toca.`n`n## Zonas protegidas`n- scripts/`n`n$line`n"
            Publish-Main $root
            $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
            $a.authority     | Should -Be 'expert' -Because "'$line' on a later line of a real FICHA is an approval"
            $a.fichaApproved | Should -Be '2026-10-02'
        }
    }
    It 'a blank Aprobada field followed by a dated line is a draft, not an approval (one line only)' {
        foreach ($body in @("# Ficha`nAprobada:`n* 2026-01-15 borrador inicial`n", "# Ficha`nAprobada:`n`n2026-01-15 kickoff`n")) {
            $root = New-ThrowawayRepo ('ref-blank' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root $body
            Publish-Main $root
            (Get-MergeAuthority -Config $null -Root $root).authority                       | Should -Be 'user'
            (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main').authority | Should -Be 'user'
        }
    }
    It 'reads a pretty-printed, multi-line committed config.json (what Set-BoardConfigValue writes)' {
        $root = New-ThrowawayRepo 'ref-prettycfg'
        Add-Expert $root
        $cfgPath = Join-Path $root '.agentic-board' 'config.json'
        Set-BoardConfigValue -Path $cfgPath -Key 'preferGroupedPRs' -Value $null | Out-Null
        Set-BoardConfigValue -Path $cfgPath -Key 'mergeAuthority' -Value 'expert' | Out-Null
        (Get-Content $cfgPath).Count | Should -BeGreaterThan 1
        Publish-Main $root
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'expert'
        $a.source    | Should -Be 'config'
    }
    It 'a lone FICHA.md (no expert) declares nothing: default, no warning, with or without the ref' {
        foreach ($body in @('Aprobada: 2026-10-01', '# Ficha sin aprobar')) {
            $root = New-ThrowawayRepo ('ref-lone' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Ficha $root $body
            Publish-Main $root
            foreach ($a in @((Get-MergeAuthority -Config $null -Root $root),
                             (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'),
                             (Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/nope'))) {
                $a.authority | Should -Be 'user'
                $a.source    | Should -Be 'default'
                $a.warning   | Should -BeNullOrEmpty
            }
        }
    }
    It 'a local opt-out reads as repo config even when the ref does not resolve' {
        $root = New-ThrowawayRepo 'ref-optout-noref'
        $a = Get-MergeAuthority -Config @{ mergeAuthority = 'user' } -Root $root -GitRef 'origin/nope'
        $a.source | Should -Be 'config'
        $g = Get-MergeAuthority -Config @{ mergeAuthority = 'none' } -Root $root -GitRef 'origin/nope'
        $g.warning | Should -Match 'user confirms'
        $g.warning | Should -Not -Match 'origin/nope' -Because 'the bad value is in the local config, not on the ref'
    }
    It 'a committed JSON array for mergeAuthority fails closed (no unrolling into a grant)' {
        foreach ($body in @('{ "mergeAuthority": [] }', '{ "mergeAuthority": ["expert"] }')) {
            $root = New-ThrowawayRepo ('ref-arr' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            Add-Expert $root
            Add-Ficha $root "Aprobada: 2026-10-01"
            New-Item -ItemType Directory -Path (Join-Path $root '.agentic-board') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.agentic-board' 'config.json') -Value $body -Encoding UTF8
            Publish-Main $root
            $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
            $a.authority | Should -Be 'user' -Because "committed config '$body'"
            $a.warning   | Should -Match 'user confirms'
        }
    }
    It 'a resolvable ref in a repo that declares nothing -> user (default), no warning' {
        $root = New-ThrowawayRepo 'ref-nothing'
        Publish-Main $root
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/main'
        $a.authority | Should -Be 'user'
        $a.source    | Should -Be 'default'
        $a.warning   | Should -BeNullOrEmpty
    }
    It 'an unresolvable ref in a repo that declares nothing -> user (default), no new warning' {
        $root = New-ThrowawayRepo 'ref-nothing-noref'
        $a = Get-MergeAuthority -Config (Get-BoardConfigDefaults) -Root $root -GitRef 'origin/main'
        $a.source  | Should -Be 'default'
        $a.warning | Should -BeNullOrEmpty
    }
    It 'a ref that does not resolve -> user, with a warning' {
        $root = New-NorteRepo 'ref-missing'
        $a = Get-MergeAuthority -Config $null -Root $root -GitRef 'origin/nope'
        $a.authority | Should -Be 'user'
        $a.warning   | Should -Match 'could not read'
    }
}

Describe 'Grouped PRs default to on when the repo declares an expert' {
    It 'nothing recorded + expert -> always, source expert' {
        Resolve-GroupingPosture (Get-BoardConfigDefaults) -ExpertDeclared | Should -Be 'always'
        $s = Get-GroupingSetting (Get-BoardConfigDefaults) -ExpertDeclared
        $s.value  | Should -Be 'on'
        $s.source | Should -Be 'expert'
        Format-GroupingSettingLabel $s | Should -Be 'on (repo expert)'
    }
    It 'a recorded answer still wins over the expert default' {
        Resolve-GroupingPosture @{ preferGroupedPRs = $false } -ExpertDeclared | Should -Be 'never'
        Resolve-GroupingPosture @{ preferGroupedPRs = 'auto' } -ExpertDeclared | Should -Be 'auto'
        (Get-GroupingSetting @{ preferGroupedPRs = $false } -ExpertDeclared).source | Should -Be 'config'
    }
    It 'without an expert nothing changes: auto, from the default' {
        Resolve-GroupingPosture (Get-BoardConfigDefaults) | Should -Be 'auto'
        (Get-GroupingSetting (Get-BoardConfigDefaults)).source | Should -Be 'default'
    }
}

Describe '-MergeAuthority end to end (no token)' {
    It 'show in a repo that declares nothing -> user (default)' {
        $root = New-ThrowawayRepo 'e2e-none'
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: user \(default\)'
        $r.out  | Should -Match 'you confirm every merge'
        $r.out  | Should -Not -Match 'could not read'
    }
    It 'show in a repo with a default branch that declares nothing -> user (default), no warning' {
        $root = New-ThrowawayRepo 'e2e-none-main'
        Publish-Main $root
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.out | Should -Match 'Merge authority: user \(default\)'
        $r.out | Should -Not -Match 'could not read|cannot be read'
    }
    It 'show follows origin/HEAD to a default branch that is not main' {
        $root = New-ThrowawayRepo 'e2e-master'
        Add-Expert $root
        Add-Ficha $root "# Ficha`n`nAprobada: 2026-10-01`n"
        git -C $root add -A 2>&1 | Out-Null
        git -C $root -c user.name=t -c user.email=t@example.com commit -q -m base 2>&1 | Out-Null
        git -C $root update-ref refs/remotes/origin/master HEAD 2>&1 | Out-Null
        git -C $root symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master 2>&1 | Out-Null
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: expert \(FICHA.md \+ expert\)'
        $r.out  | Should -Match 'git show origin/master:'
    }
    It 'show on a PR branch that ADDS an approved FICHA + expert -> user (Board-Work reads the default branch)' {
        $root = New-ThrowawayRepo 'e2e-attack'
        Publish-Main $root
        git -C $root checkout -q -b issue-1-grant 2>&1 | Out-Null
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        git -C $root add -A 2>&1 | Out-Null
        git -C $root -c user.name=t -c user.email=t@example.com commit -q -m grant 2>&1 | Out-Null
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: user \(default\)'
    }
    It 'show in a NORTE repo -> expert, and the gate still runs' {
        $root = New-NorteRepo 'e2e-norte'
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: expert \(FICHA.md \+ expert\)'
        $r.out  | Should -Match 'review gate still runs'
        $r.out  | Should -Match 'git show origin/main:\.claude/agents/experto\.md'
    }
    It 'records user, reads it back, and auto clears it again' {
        $root = New-NorteRepo 'e2e-write'
        $w = Invoke-BoardWork $root @{ MergeAuthority = 'user' }
        $w.code | Should -Be 0
        $w.out  | Should -Match 'In force now: user \(repo config\)'
        $cfg = Get-Content (Join-Path $root '.agentic-board' 'config.json') -Raw | ConvertFrom-Json
        $cfg.mergeAuthority | Should -Be 'user'

        $c = Invoke-BoardWork $root @{ MergeAuthority = 'auto' }
        $c.code | Should -Be 0
        $c.out  | Should -Match 'In force now: expert \(FICHA.md \+ expert\)'
    }
    It 'the grouped-PR setting shows on (repo expert) in a NORTE repo' {
        $root = New-NorteRepo 'e2e-group'
        $r = Invoke-BoardWork $root @{ PreferGroupedPRs = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Grouped PRs: on \(repo expert\)'
    }
    It 'show with an unreadable config.json in a NORTE repo -> user' {
        $root = New-NorteRepo 'e2e-corrupt'
        New-Item -ItemType Directory -Path (Join-Path $root '.agentic-board') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root '.agentic-board' 'config.json') -Value '{ not json' -Encoding UTF8
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: user \(repo config\)'
        $r.out  | Should -Match 'cannot be read'
    }
    It '-PreferGroupedPRs auto in a NORTE repo is honoured as auto, not the expert default' {
        $root = New-NorteRepo 'e2e-auto'
        $w = Invoke-BoardWork $root @{ PreferGroupedPRs = 'auto' }
        $w.code | Should -Be 0
        $r = Invoke-BoardWork $root @{ PreferGroupedPRs = 'show' }
        $r.out  | Should -Match 'Grouped PRs: auto \(repo config\)'
    }
    It '-PreferGroupedPRs auto in a repo that declares nothing still stores no decision' {
        $root = New-ThrowawayRepo 'e2e-auto-none'
        $w = Invoke-BoardWork $root @{ PreferGroupedPRs = 'auto' }
        $w.code | Should -Be 0
        $cfg = Get-Content (Join-Path $root '.agentic-board' 'config.json') -Raw | ConvertFrom-Json
        $cfg.preferGroupedPRs | Should -BeNullOrEmpty
    }
    It 'the grouped-PR setting is unchanged in a repo that declares nothing' {
        $root = New-ThrowawayRepo 'e2e-group-none'
        $r = Invoke-BoardWork $root @{ PreferGroupedPRs = 'show' }
        $r.out | Should -Match 'Grouped PRs: auto \(default\)'
    }
}

Describe 'verbs-work.md step 5d documents the expert branch' {
    BeforeAll {
        $script:Doc = Get-Content (Join-Path $script:Plugin 'skills' 'projects-admin' 'references' 'verbs-work.md') -Raw
    }
    It 'step 5d reads the merge authority first' {
        # Anchored on the step-5d block itself, not the summary table further down.
        $script:Doc | Should -Match '(?s)\*\*Who decides the merge \(#797\)\.\*\*\s+Before step d, run `scripts/Board-Work\.ps1 -MergeAuthority\s+show`'
    }
    It 'says the review gate always runs and repos that declare nothing keep the user confirmation' {
        $script:Doc | Should -Match '(?s)declares nothing.{0,200}(today|unchanged)'
        $script:Doc | Should -Match '(?i)gate (still|always) runs'
    }
    It 'a PR that touches the rules of the merge is propose, and the judge comes from the default branch' {
        $script:Doc | Should -Match '(?s)A PR whose diff touches `FICHA\.md`, `\.claude/agents/experto\.md` or\s+`\.agentic-board/config\.json` is `propose`'
        $script:Doc | Should -Match 'The judge and its plan come from the default branch'
    }
}
