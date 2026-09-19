#Requires -Modules Pester
<#  Tests for the Expert-Auto fixes of #472 (-TakeOver/-IgnoreBlocked passthrough), #499
    (-Owner/-Repo), #473 (issue comments in the brief) and #554 (capability map vs auto-loop.md).

    Two layers, on purpose. The pure cores (Format-IssueComments, Resolve-AutoTokenVar,
    Get-AutoBoardUrl, Format-AutoBrief) are driven directly. The forwarding itself is a property of
    the CLI half, which no pure core can show - so the real Expert-Auto.ps1 is RUN, in a scratch
    copy of scripts/, against a scripted `gh` and a Board-Work stand-in that records exactly the
    parameters it is handed. Mocking the function under test would prove nothing here. #>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:Script     = Join-Path $script:ScriptsDir 'Expert-Auto.ps1'
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTAUTO_DOTSOURCE = ''
    $script:Contract = @{
        role = 'You are an expert in powerbi-report. Objective: ship a bar chart.'
        autonomy = @{ irreversible = @('merge', 'deploy', 'refresh', 'publish', 'delete') }
        dod = @{ ci = $true; tests = $true }
        budget = @{ maxIterations = 8; maxMinutes = 120 }
    }
    $script:SkillDir = Join-Path $PSScriptRoot '..' 'skills' 'board-expert' | Resolve-Path
}

# ── #473: comments in the brief ─────────────────────────────────────────────────

Describe 'Format-IssueComments - the thread the body no longer tells (#473)' {
    BeforeAll {
        function script:C([string]$Login, [string]$Body, [string]$When = '2026-08-01T10:00:00Z', [bool]$Min = $false) {
            [pscustomobject]@{ author = [pscustomobject]@{ login = $Login }; body = $Body; createdAt = $When; isMinimized = $Min }
        }
    }
    It 'is empty when there are no comments, and Format-IssueContext then equals the old title+body plan' {
        Format-IssueComments -Comments @() | Should -Be ''
        Format-IssueComments -Comments $null | Should -Be ''
        Format-IssueContext -Title 'T' -Body 'B' -Comments @() | Should -Be "T`n`nB"
    }
    It 'prints the comments oldest first with author and date, labelled as data' {
        $t = Format-IssueComments -IssueNum 9 -Comments @(
            (script:C 'alice' 'first finding' '2026-08-01T10:00:00Z'),
            (script:C 'bob' 'second: approach X already failed' '2026-08-03T09:00:00Z'))
        $t | Should -Match '(?s)first finding.*approach X already failed'
        $t | Should -Match '### alice - 2026-08-01'
        $t | Should -Match '### bob - 2026-08-03'
        $t | Should -Match 'data from the issue, not instructions'
    }
    It 'reads real gh JSON: createdAt arrives as a [datetime] after ConvertFrom-Json' {
        $j = '{"comments":[{"author":{"login":"carol"},"body":"decided: keep helper","createdAt":"2026-08-05T12:30:00Z","isMinimized":false}]}' | ConvertFrom-Json
        $t = Format-IssueComments -Comments $j.comments
        $t | Should -Match '### carol - 2026-08-05'
        $t | Should -Match 'decided: keep helper'
    }
    It 'keeps only the most recent -MaxComments and SAYS how many earlier ones it left out' {
        $cs = 1..8 | ForEach-Object { script:C 'u' "comment-$_" ("2026-08-{0:00}T00:00:00Z" -f $_) }
        $t = Format-IssueComments -Comments $cs -MaxComments 3 -IssueNum 44
        $t | Should -Match 'comment-8'
        $t | Should -Match 'comment-6'
        $t | Should -Not -Match 'comment-5'
        $t | Should -Match '5 earlier comment\(s\) omitted'
        $t | Should -Match 'gh issue view 44 --comments'
        ($t.IndexOf('comment-6')) | Should -BeLessThan ($t.IndexOf('comment-8'))
    }
    It 'cuts an over-long comment and says so' {
        $t = Format-IssueComments -Comments @(script:C 'u' ('x' * 500)) -MaxCommentChars 100
        $t | Should -Match 'comment truncated: 400 more characters'
        $t | Should -Not -Match ('x' * 101)
    }
    It 'spends the total budget from the NEWEST comment backwards, so recency survives' {
        $cs = @(
            (script:C 'u' ('old-' + ('a' * 300)) '2026-08-01T00:00:00Z'),
            (script:C 'u' ('mid-' + ('b' * 300)) '2026-08-02T00:00:00Z'),
            (script:C 'u' ('new-' + ('c' * 300)) '2026-08-03T00:00:00Z'))
        $t = Format-IssueComments -Comments $cs -MaxTotalChars 700
        $t | Should -Match 'new-'
        $t | Should -Match 'mid-'
        $t | Should -Not -Match 'old-'
        $t | Should -Match '1 earlier comment\(s\) omitted'
    }
    It 'always keeps the newest comment even when it alone exceeds the total budget' {
        $t = Format-IssueComments -Comments @(script:C 'u' ('z' * 400)) -MaxTotalChars 50 -MaxCommentChars 1000
        $t | Should -Match ('z' * 400)
    }
    It 'skips minimised comments and the tool''s own claim/stall bookkeeping' {
        $t = Format-IssueComments -Comments @(
            (script:C 'spam' 'buy pills' '2026-08-01T00:00:00Z' $true),
            (script:C 'bot' '[abios-claim] fingerprint=abc' '2026-08-02T00:00:00Z'),
            (script:C 'bot' '[abios-stall] no progress' '2026-08-02T01:00:00Z'),
            (script:C 'dana' 'the real decision' '2026-08-03T00:00:00Z'))
        $t | Should -Match 'the real decision'
        $t | Should -Not -Match 'buy pills'
        $t | Should -Not -Match 'abios-claim'
        $t | Should -Not -Match 'abios-stall'
    }
    It 'returns nothing when every comment is filtered out' {
        Format-IssueComments -Comments @(script:C 'bot' '[abios-claim] x') | Should -Be ''
    }
    It 'a thread that cannot be rendered costs the comments, not the plan: title + body survive, with a warning' {
        # (a script-property getter that throws is swallowed to $null by PowerShell itself, so the
        # value must be a real .NET object whose ToString() throws when the date is stringified)
        if (-not ('AutoTestBoom' -as [type])) {
            Add-Type -TypeDefinition 'public class AutoTestBoom { public override string ToString() { throw new System.InvalidOperationException("boom"); } }'
        }
        $bad = [pscustomobject]@{ author = $null; createdAt = [AutoTestBoom]::new(); body = 'x'; isMinimized = $false }
        $WarningPreference = 'Continue'
        $all = @(Format-IssueContext -Title 'T' -Body 'B' -Comments @($bad) -IssueNum 3 3>&1)
        @($all | Where-Object { $_ -is [string] })[0] | Should -Be "T`n`nB"
        (@($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })[0]).Message | Should -Match 'could not fold the comments of #3'
    }
    It 'Format-IssueContext appends the discussion after title and body' {
        $t = Format-IssueContext -Title 'Title' -Body 'Body text' -Comments @(script:C 'u' 'a later decision')
        $t | Should -Match '(?s)^Title\r?\n\r?\nBody text.*Issue discussion.*a later decision'
    }
}

# ── #499: identity + board URL ──────────────────────────────────────────────────

Describe 'Resolve-AutoTokenVar - the account follows the owner, never a wider one (#499)' {
    It 'no owner, no explicit var: the default variable, untouched' {
        $r = Resolve-AutoTokenVar -TokenVar 'GITHUB_TOKEN_PERSONAL' -TokenVarExplicit $false -Owner ''
        $r.var | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.explicit | Should -BeFalse
    }
    It 'a mapped second-account owner resolves through the suite''s one owner map' {
        $r = Resolve-AutoTokenVar -TokenVar 'GITHUB_TOKEN_PERSONAL' -TokenVarExplicit $false -Owner 'PAL-Devs'
        $r.var | Should -Be (Get-OwnerTokenVar -Owner 'PAL-Devs')
        $r.var | Should -Be 'GITHUB_TOKEN_BUSINESS'
        $r.mapped | Should -BeTrue
    }
    It 'an explicit -TokenVar always wins over the owner map' {
        $r = Resolve-AutoTokenVar -TokenVar 'MY_OWN_VAR' -TokenVarExplicit $true -Owner 'PAL-Devs'
        $r.var | Should -Be 'MY_OWN_VAR'
        $r.explicit | Should -BeTrue
    }
    It 'an owner the map does not know keeps the default variable and is flagged unmapped - no widening' {
        $r = Resolve-AutoTokenVar -TokenVar 'GITHUB_TOKEN_PERSONAL' -TokenVarExplicit $false -Owner 'someone-new'
        $r.var | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.mapped | Should -BeFalse
        $r.var | Should -Not -Be 'GITHUB_TOKEN_BUSINESS'
    }
}

Describe 'Get-AutoBoardUrl - user AND org boards (#499)' {
    It 'trusts the board''s own url for an org-owned board' {
        Get-AutoBoardUrl -Owner 'acme' -ProjectNum 4 -ResolvedUrl 'https://github.com/orgs/acme/projects/4' | Should -Be 'https://github.com/orgs/acme/projects/4'
    }
    It 'trusts the board''s own url for a user-owned board' {
        Get-AutoBoardUrl -Owner 'bob' -ProjectNum 2 -ResolvedUrl 'https://github.com/users/bob/projects/2' | Should -Be 'https://github.com/users/bob/projects/2'
    }
    It 'falls back to the user-board shape when nothing was resolved' {
        Get-AutoBoardUrl -Owner 'bob' -ProjectNum 2 | Should -Be 'https://github.com/users/bob/projects/2'
    }
    It 'refuses a resolved value that is not a github.com project link' {
        Get-AutoBoardUrl -Owner 'bob' -ProjectNum 2 -ResolvedUrl 'https://evil.example/orgs/x/projects/1' | Should -Be 'https://github.com/users/bob/projects/2'
        Get-AutoBoardUrl -Owner 'bob' -ProjectNum 2 -ResolvedUrl 'not a url' | Should -Be 'https://github.com/users/bob/projects/2'
    }
}

# ── #554: the capability map cannot drift from auto-loop.md ─────────────────────

Describe 'The brief''s capability map agrees with the docs that describe it (#554)' {
    BeforeAll {
        function script:Get-BriefMapTokens {
            $b = Format-AutoBrief -Contract $script:Contract -PlanBody 'x' -RoleObjective 'r'
            $m = [regex]::Match($b, '(?s)### Capability map.*?\r?\n(.*?)(?=\r?\n### )')
            if (-not $m.Success) { throw 'capability map section not found in the rendered brief' }
            @([regex]::Matches($m.Groups[1].Value, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }
        function script:Get-DocMapTokens([string]$Path) {
            $lines = @(Get-Content -LiteralPath $Path)
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\|\s*Need\s*\|\s*Capability\s*\|') { $start = $i; break } }
            if ($start -lt 0) { throw "no '| Need | Capability |' table in $Path" }
            $out = @()
            for ($i = $start + 2; $i -lt $lines.Count -and $lines[$i] -match '^\|'; $i++) {
                $cells = $lines[$i].Trim().Trim('|') -split '\|', 2
                $out += @([regex]::Matches($cells[1], '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
            }
            @($out | Sort-Object -Unique)
        }
        $script:BriefTokens = script:Get-BriefMapTokens
    }
    It 'the parsers are not vacuous - they see the map' {
        $script:BriefTokens.Count | Should -BeGreaterThan 10
        $script:BriefTokens | Should -Contain '/knowledge add'
    }
    It 'names the four commands the map used to miss' -ForEach @(
        @{ Cmd = '/skills freshness' }, @{ Cmd = '/board doctor' }, @{ Cmd = '/board cerrar-ciclo' }, @{ Cmd = '/board changelog' }
    ) {
        $script:BriefTokens | Should -Contain $Cmd
    }
    It '<Doc>: every capability it lists is in the brief, and every capability in the brief is listed' -ForEach @(
        @{ Doc = 'references/auto-loop.md' }, @{ Doc = 'SKILL.md' }
    ) {
        $docTokens = script:Get-DocMapTokens (Join-Path $script:SkillDir $Doc)
        $missingFromBrief = @($docTokens | Where-Object { $script:BriefTokens -notcontains $_ })
        $missingFromDoc   = @($script:BriefTokens | Where-Object { $docTokens -notcontains $_ })
        $missingFromBrief | Should -BeNullOrEmpty -Because "the launched session only gets the brief's map: $Doc lists $($missingFromBrief -join ', ') that it lacks"
        $missingFromDoc   | Should -BeNullOrEmpty -Because "the brief names $($missingFromDoc -join ', ') that $Doc does not list"
    }
}

# ── The CLI half, run for real ──────────────────────────────────────────────────

Describe 'Expert-Auto.ps1 end to end - the overrides reach the launch (#472, #499) and the comments reach the brief (#473)' {
    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("expauto-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Scripts = Join-Path $script:Root 'scripts'
        $script:Fix     = Join-Path $script:Root 'fixtures'
        $script:Clone   = Join-Path $script:Root 'clone'
        New-Item -ItemType Directory -Path $script:Scripts, $script:Fix, $script:Clone -Force | Out-Null
        Copy-Item -Path (Join-Path $script:ScriptsDir '*') -Destination $script:Scripts -Recurse -Force

        # The Board-Work stand-in: same parameter names the real one has (asserted separately
        # below), and it records exactly what it was handed - key -> value, switches as booleans.
        $stub = @'
[CmdletBinding()]
param(
    [string]$Owner = "CSalcedoDataBI", [string]$Repo = "", [int]$ProjectNum = 0, [string[]]$Parallel = @(),
    [switch]$Launch, [switch]$StopAtPR, [string]$BriefFile = "", [string[]]$Irreversible = @(),
    [switch]$EndToEnd, [int]$BudgetMinutes = 0, [string]$TokenVar = "GITHUB_TOKEN_PERSONAL",
    [switch]$TakeOver, [switch]$IgnoreBlocked
)
$rec = [ordered]@{}
foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    $rec[$k] = if ($v -is [System.Management.Automation.SwitchParameter]) { [bool]$v } else { $v }
}
($rec | ConvertTo-Json -Compress) | Add-Content -LiteralPath $env:FAKE_BW_LOG
exit 0
'@
        Set-Content -LiteralPath (Join-Path $script:Scripts 'Board-Work.ps1') -Value $stub -Encoding utf8

        # A scripted gh: answers from fixture files, logs every call, exits non-zero for the rest.
        $fake = @'
$a = @($args)
# `--json title,body,comments` reaches a FUNCTION as an array (a native gh gets it comma-joined);
# join it back so the log shows what gh would have been asked.
$all = ($a | ForEach-Object { if ($_ -is [array]) { $_ -join ',' } else { "$_" } }) -join ' '
Add-Content -LiteralPath $env:FAKE_GH_LOG -Value $all
$dir = $env:FAKE_GH_DIR
if ($a[0] -eq 'issue' -and $a[1] -eq 'view') {
    $f = Join-Path $dir ("issue-{0}.json" -f $a[2])
    if (Test-Path $f) { Get-Content -Raw -LiteralPath $f; exit 0 }
    exit 1
}
if ($a[0] -eq 'api' -and $a[1] -eq 'graphql') {
    if ($all -match 'subIssues') { Get-Content -Raw -LiteralPath (Join-Path $dir 'subissues.json'); exit 0 }
    if ($all -match 'closedByPullRequestsReferences') {
        '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'; exit 0
    }
    exit 1
}
if ($a[0] -eq 'api' -and $all -match 'dependencies/blocked_by') { '[]'; exit 0 }
if ($a[0] -eq 'project' -and $a[1] -eq 'view') {
    $f = Join-Path $dir 'project.json'
    if (Test-Path $f) { Get-Content -Raw -LiteralPath $f; exit 0 }
    exit 1
}
exit 1
'@
        Set-Content -LiteralPath (Join-Path $script:Fix 'gh-fake.ps1') -Value $fake -Encoding utf8

        $issue = @{
            title = 'Fix the thing'; body = 'ORIGINAL REPORT BODY'
            comments = @(
                @{ author = @{ login = 'alice' }; body = 'Tried approach X; it failed because Y.'; createdAt = '2026-08-01T10:00:00Z'; isMinimized = $false }
                @{ author = @{ login = 'bob' };   body = 'Decision: keep the helper, try Z next.'; createdAt = '2026-08-02T10:00:00Z'; isMinimized = $false }
            )
        }
        $issue | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Fix 'issue-7.json') -Encoding utf8
        @{ title = 'Plain'; body = 'no thread here'; comments = @() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Fix 'issue-8.json') -Encoding utf8
        @{ title = 'The epic'; body = 'EPIC BODY'; comments = @(@{ author = @{ login = 'erin' }; body = 'epic-level decision: waves stay small'; createdAt = '2026-08-01T00:00:00Z'; isMinimized = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Fix 'issue-100.json') -Encoding utf8
        @{ title = 'Sub one'; body = 'SUB ONE BODY'; comments = @(@{ author = @{ login = 'frank' }; body = 'sub-level dead end: do not use the cache'; createdAt = '2026-08-02T00:00:00Z'; isMinimized = $false }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Fix 'issue-101.json') -Encoding utf8
        @{ title = 'Sub two'; body = 'SUB TWO BODY'; comments = @() } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:Fix 'issue-102.json') -Encoding utf8
        '{"data":{"repository":{"issue":{"subIssues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":101,"title":"Sub one","state":"OPEN","repository":{"nameWithOwner":"acme/widgets"}},{"number":102,"title":"Sub two","state":"OPEN","repository":{"nameWithOwner":"acme/widgets"}}]}}}}}' |
            Set-Content -LiteralPath (Join-Path $script:Fix 'subissues.json') -Encoding utf8

        # A git clone with no origin: Expert-Auto's `git fetch origin` then fails fast (no network,
        # no credential prompt) and -Repo names the target explicitly.
        Push-Location $script:Clone
        try { git init -q 2>$null | Out-Null } finally { Pop-Location }

        $script:Saved = @{}
        foreach ($n in 'GH_TOKEN', 'FAKE_BW_LOG', 'FAKE_GH_LOG', 'FAKE_GH_DIR', 'GIT_TERMINAL_PROMPT') { $script:Saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        $env:GH_TOKEN = 'test-token-not-real'          # skips the registry-token block: nothing here reads a real token
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:FAKE_GH_DIR = $script:Fix
        $env:FAKE_BW_LOG = Join-Path $script:Root 'bw.log'
        $env:FAKE_GH_LOG = Join-Path $script:Root 'gh.log'

        # Run the REAL Expert-Auto.ps1 (from the scratch copy) with `gh` shadowed by a function.
        function script:Invoke-Auto([string]$ArgText, [string]$Cwd = '') {
            if (-not $Cwd) { $Cwd = $script:Clone }
            Remove-Item -LiteralPath $env:FAKE_BW_LOG, $env:FAKE_GH_LOG -Force -ErrorAction SilentlyContinue
            $ea   = Join-Path $script:Scripts 'Expert-Auto.ps1'
            $gh   = Join-Path $script:Fix 'gh-fake.ps1'
            # $Cwd goes in single-quoted: a typographic apostrophe in it is the point of one test,
            # so it is doubled the way the tokenizer wants (all four quote characters).
            $cwdLit = $Cwd -replace "(['‘’‚‛])", '$1$1'
            $cmd  = "function gh { & '$gh' @args }; Set-Location '$cwdLit'; & '$ea' $ArgText"
            $out  = (& pwsh -NoProfile -Command $cmd 2>&1 | Out-String)
            $calls = @()
            if (Test-Path $env:FAKE_BW_LOG) { $calls = @(Get-Content -LiteralPath $env:FAKE_BW_LOG | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }) }
            [pscustomobject]@{ Out = $out; Calls = $calls }
        }
        function script:Get-Brief([int]$N) {
            Get-Content -Raw -LiteralPath (Join-Path $script:Clone ".agentic-board/expert-brief-$N.md")
        }
    }
    AfterAll {
        foreach ($n in $script:Saved.Keys) { [Environment]::SetEnvironmentVariable($n, $script:Saved[$n]) }
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Board-Work really declares every parameter Expert-Auto forwards (the stand-in cannot lie about names)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ScriptsDir 'Board-Work.ps1'), [ref]$null, [ref]$null)
        $declared = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($p in 'Owner', 'Repo', 'TakeOver', 'IgnoreBlocked', 'TokenVar', 'ProjectNum', 'Parallel', 'Launch', 'StopAtPR', 'BriefFile', 'Irreversible', 'EndToEnd', 'BudgetMinutes') {
            $declared | Should -Contain $p
        }
    }

    It 'passes NOTHING extra when no override was asked for (defaults unchanged)' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13'
        $r.Calls.Count | Should -Be 1
        $r.Calls[0].Keys | Should -Not -Contain 'Owner'
        $r.Calls[0].Keys | Should -Not -Contain 'Repo'
        $r.Calls[0].Keys | Should -Not -Contain 'TakeOver'
        $r.Calls[0].Keys | Should -Not -Contain 'IgnoreBlocked'
        $r.Calls[0].TokenVar | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $r.Calls[0].Parallel | Should -Be '8'
    }

    It '#499: a repo DERIVED from origin is used for reads but is NOT forwarded as if the human had passed -Repo' {
        # `$repo` (derived) and `$Repo` (the parameter) are the same PowerShell variable; forwarding
        # on `if ($Repo)` after the derivation would silently pass -Repo on every run.
        Push-Location $script:Clone
        try {
            git config http.proxy http://127.0.0.1:9      # `git fetch origin` then fails at once, offline
            git remote add origin https://github.com/acme/widgets.git
        } finally { Pop-Location }
        try {
            $s = script:Invoke-Auto '-Issue 8 -ProjectNum 13'
            $s.Calls.Count | Should -Be 1
            $s.Calls[0].Keys | Should -Not -Contain 'Repo'
            (Get-Content -Raw -LiteralPath $env:FAKE_GH_LOG) | Should -Match 'issue view 8 --repo acme/widgets'
            $e = script:Invoke-Auto '-Epic 100 -ProjectNum 13'
            $e.Calls.Count | Should -Be 2
            foreach ($c in $e.Calls) { $c.Keys | Should -Not -Contain 'Repo' }
            $d = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -DryRun'
            $d.Out | Should -Not -Match '-Repo '
        } finally {
            Push-Location $script:Clone
            try { git remote remove origin 2>$null } finally { Pop-Location }
        }
    }

    It '#472: forwards -TakeOver and -IgnoreBlocked to Board-Work when the human passed them' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Repo acme/widgets -TakeOver -IgnoreBlocked'
        $r.Calls.Count | Should -Be 1
        $r.Calls[0].TakeOver | Should -BeTrue
        $r.Calls[0].IgnoreBlocked | Should -BeTrue
    }

    It '#472: each override travels alone - -TakeOver does not smuggle -IgnoreBlocked' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Repo acme/widgets -TakeOver'
        $r.Calls[0].TakeOver | Should -BeTrue
        $r.Calls[0].Keys | Should -Not -Contain 'IgnoreBlocked'
    }

    It '#499: forwards -Owner and -Repo, and resolves the token variable FROM the owner' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner PAL-Devs -Repo acme/widgets'
        $r.Calls[0].Owner | Should -Be 'PAL-Devs'
        $r.Calls[0].Repo | Should -Be 'acme/widgets'
        $r.Calls[0].TokenVar | Should -Be 'GITHUB_TOKEN_BUSINESS'
    }

    It '#499: an explicit -TokenVar beats the owner map; an unmapped owner warns and keeps the default variable' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner PAL-Devs -TokenVar MY_SECOND_TOKEN'
        $r.Calls[0].TokenVar | Should -Be 'MY_SECOND_TOKEN'
        $u = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner someone-new'
        $u.Calls[0].TokenVar | Should -Be 'GITHUB_TOKEN_PERSONAL'
        $u.Out | Should -Match "Owner 'someone-new' is not in the owner->token map"
    }

    It '#499: a malformed -Repo is refused before anything is launched' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Repo not-a-repo'
        $r.Calls.Count | Should -Be 0
        $r.Out | Should -Match '-Repo must be owner/name'
    }

    It '#499: an -Owner, -Repo or -TokenVar that is not shaped like what it names is refused before anything travels' -ForEach @(
        @{ Bad = "-Owner 'x; Write-Host pwn'" }
        @{ Bad = "-Owner ""x$([char]0x2019); Write-Host pwn; #""" }
        @{ Bad = "-Repo 'a/b; Write-Host pwn'" }
        @{ Bad = '-Repo "a/b''c"' }
        @{ Bad = "-TokenVar 'A B'" }
    ) {
        $r = script:Invoke-Auto "-Issue 8 -ProjectNum 13 $Bad"
        $r.Calls.Count | Should -Be 0
        $r.Out | Should -Match 'Expert-Auto: -(Owner|Repo|TokenVar) must be'
    }

    It '#499: real-looking account and repo names (dots, underscores, hyphens, single characters) are NOT refused' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner some.org_x-1 -Repo some.org_x-1/my.repo_name-2'
        $r.Calls.Count | Should -Be 1
        $r.Calls[0].Owner | Should -Be 'some.org_x-1'
        $r.Calls[0].Repo | Should -Be 'some.org_x-1/my.repo_name-2'
        $one = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner a -Repo a/b'
        $one.Calls.Count | Should -Be 1
    }

    It 'the epic walker survives a clone path holding a typographic apostrophe (no injection into its child command)' {
        # U+2019 is a single-quote character to the PowerShell tokenizer; a naive '-doubling leaves
        # it live, so the rest of this directory NAME would run as a command in the child.
        $evil = Join-Path $script:Root ("o$([char]0x2019); New-Item -ItemType File -Name injected-marker.txt; #")
        New-Item -ItemType Directory -Path $evil -Force | Out-Null
        Push-Location $evil
        try { git init -q 2>$null | Out-Null } finally { Pop-Location }
        $r = script:Invoke-Auto '-Epic 100 -ProjectNum 13 -Repo acme/widgets' $evil
        $r.Calls.Count | Should -Be 2
        $r.Calls[0].BriefFile | Should -BeLike "*o$([char]0x2019); New-Item -ItemType File -Name injected-marker.txt; #*expert-brief-101.md"
        Test-Path -LiteralPath (Join-Path $evil 'injected-marker.txt') | Should -BeFalse
    }

    It '#499: the -DryRun launch line shows the overrides so it can be pasted as-is' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner PAL-Devs -Repo acme/widgets -TakeOver -IgnoreBlocked -DryRun'
        $r.Calls.Count | Should -Be 0
        $r.Out | Should -Match '/board work .*-Owner PAL-Devs -TokenVar GITHUB_TOKEN_BUSINESS'
        $r.Out | Should -Match '-Repo acme/widgets'
        $r.Out | Should -Match '-TakeOver'
        $r.Out | Should -Match '-IgnoreBlocked'
    }

    It '#499: the closing board link comes from the board itself, so an org board says /orgs/' {
        '{"url":"https://github.com/orgs/acme/projects/13","number":13}' | Set-Content -LiteralPath (Join-Path $script:Fix 'project.json') -Encoding utf8
        try {
            $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner acme -Repo acme/widgets -DryRun'
            $r.Out | Should -Match 'Board: https://github.com/orgs/acme/projects/13'
        } finally { Remove-Item -LiteralPath (Join-Path $script:Fix 'project.json') -Force }
    }

    It '#499: when the board cannot be read the link falls back to the user-board shape for the named owner' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Owner PAL-Devs -Repo acme/widgets -DryRun'
        $r.Out | Should -Match 'Board: https://github.com/users/PAL-Devs/projects/13'
    }

    It '#473: the single-issue brief carries the comment thread, in order, after the body' {
        $r = script:Invoke-Auto '-Issue 7 -ProjectNum 13 -Repo acme/widgets -DryRun'
        $b = script:Get-Brief 7
        $b | Should -Match 'ORIGINAL REPORT BODY'
        $b | Should -Match 'Tried approach X; it failed because Y\.'
        $b | Should -Match 'Decision: keep the helper, try Z next\.'
        $b.IndexOf('ORIGINAL REPORT BODY') | Should -BeLessThan $b.IndexOf('Tried approach X')
        $b.IndexOf('Tried approach X') | Should -BeLessThan $b.IndexOf('Decision: keep the helper')
        $b | Should -Match '### alice - 2026-08-01'
        # the fetch itself must ask gh for comments - a fixture returns them regardless of --json
        (Get-Content -Raw -LiteralPath $env:FAKE_GH_LOG) | Should -Match 'issue view 7 .*--json title,body,comments'
    }

    It '#473: an issue with no comments gets no discussion section' {
        $r = script:Invoke-Auto '-Issue 8 -ProjectNum 13 -Repo acme/widgets -DryRun'
        (script:Get-Brief 8) | Should -Not -Match 'Issue discussion'
    }

    It '#472 + #473 in the epic walker: overrides reach every child launch and both threads reach each brief' {
        $r = script:Invoke-Auto '-Epic 100 -ProjectNum 13 -Owner PAL-Devs -Repo acme/widgets -TakeOver -IgnoreBlocked'
        $r.Calls.Count | Should -Be 2
        foreach ($c in $r.Calls) {
            $c.Owner | Should -Be 'PAL-Devs'
            $c.Repo | Should -Be 'acme/widgets'
            $c.TokenVar | Should -Be 'GITHUB_TOKEN_BUSINESS'
            $c.TakeOver | Should -BeTrue
            $c.IgnoreBlocked | Should -BeTrue
        }
        $b1 = script:Get-Brief 101
        $b1 | Should -Match 'epic-level decision: waves stay small'
        $b1 | Should -Match 'sub-level dead end: do not use the cache'
        $b1 | Should -Match 'SUB ONE BODY'
        (script:Get-Brief 102) | Should -Not -Match 'sub-level dead end'
    }

    It 'epic walker without overrides forwards none of them' {
        $r = script:Invoke-Auto '-Epic 100 -ProjectNum 13 -Repo acme/widgets'
        $r.Calls.Count | Should -Be 2
        foreach ($c in $r.Calls) {
            $c.Keys | Should -Not -Contain 'Owner'
            $c.Keys | Should -Not -Contain 'TakeOver'
            $c.Keys | Should -Not -Contain 'IgnoreBlocked'
        }
    }
}
