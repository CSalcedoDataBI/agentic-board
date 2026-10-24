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
    function Invoke-BoardWork([string]$Dir, [hashtable]$Params) {
        $saved = $env:GH_TOKEN
        $env:GH_TOKEN = ''
        try {
            Push-Location $Dir
            $out = & $script:Script @Params -TokenVar 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST' 6>&1 2>&1 | Out-String
            $code = $LASTEXITCODE
            Pop-Location
            [pscustomobject]@{ out = $out; code = $code }
        } finally { $env:GH_TOKEN = $saved }
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
    It 'an unrecognised mergeAuthority is ignored with a warning, and the files decide' {
        $root = New-ThrowawayRepo 'garbage'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        foreach ($garbage in @('maybe', 42, $true)) {
            $a = Get-MergeAuthority -Config @{ mergeAuthority = $garbage } -Root $root
            $a.authority | Should -Be 'expert' -Because "'$garbage' is not a decision"
            $a.warning   | Should -Match 'ignored'
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
    }
    It 'show in a NORTE repo -> expert, and the gate still runs' {
        $root = New-ThrowawayRepo 'e2e-norte'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        $r = Invoke-BoardWork $root @{ MergeAuthority = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Merge authority: expert \(FICHA.md \+ expert\)'
        $r.out  | Should -Match 'review gate still runs'
    }
    It 'records user, reads it back, and auto clears it again' {
        $root = New-ThrowawayRepo 'e2e-write'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
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
        $root = New-ThrowawayRepo 'e2e-group'
        Add-Expert $root
        Add-Ficha $root "Aprobada: 2026-10-01"
        $r = Invoke-BoardWork $root @{ PreferGroupedPRs = 'show' }
        $r.code | Should -Be 0
        $r.out  | Should -Match 'Grouped PRs: on \(repo expert\)'
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
        $script:Doc | Should -Match 'MergeAuthority show'
    }
    It 'says the review gate always runs and repos that declare nothing keep the user confirmation' {
        $script:Doc | Should -Match '(?s)declares nothing.{0,200}(today|unchanged)'
        $script:Doc | Should -Match '(?i)gate (still|always) runs'
    }
}
