#Requires -Modules Pester
<#  Tests for Board-Depend.ps1 - native blocked-by dependencies, verified (#521).

    The trap: POST .../dependencies/blocked_by takes the issue's DATABASE id. Send the NUMBER and
    GitHub does not fail - it links whichever issue anywhere carries that id (observed:
    {"issue_id": 17} linked jbarnette/johnson#3). The script must resolve number -> id, refuse
    anything outside the target repo, and read the list back.

    The world is a fake `gh` at the process seam (Invoke-GhRaw): a small stateful GitHub with a
    GLOBAL table of database ids that includes strangers, so sending a number really does link the
    wrong issue - the tests would catch a regression to the raw behaviour, not just describe it.
    Everything above the seam (Invoke-Gh's parsing, the resolver, the verifier) is the real code.  #>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Depend.ps1' | Resolve-Path
    $env:ABIOS_BOARDDEPEND_DOTSOURCE = '1'
    . $script:ScriptPath
    $env:ABIOS_BOARDDEPEND_DOTSOURCE = $null

    # Build a fresh fake GitHub. Issue database ids deliberately differ from numbers (id = 90000 + n)
    # so "number sent as id" can never accidentally equal the right issue; and the low ids 17 / 5
    # belong to STRANGERS in other repositories, like the real incident.
    function script:New-World {
        $w = @{ Posts = @(); Links = @{}; ById = @{}; ByKey = @{}; Mode = 'normal'; Reads = 0; InjectOnRead = 0 }
        foreach ($n in 1..60) {
            $e = @{ id = 90000 + $n; number = $n; repo = 'me/proj'; state = 'open'; title = "task $n"; pr = $false }
            $w.ById[[long]$e.id] = $e; $w.ByKey["me/proj#$n"] = $e
        }
        $w.ById[[long]17]  = @{ id = 17; number = 3;  repo = 'jbarnette/johnson'; state = 'open'; title = 'Third issue'; pr = $false }
        $w.ById[[long]5]   = @{ id = 5;  number = 12; repo = 'someone/else';      state = 'open'; title = 'Unrelated';    pr = $false }
        # a PR in the target repo (number 50) and an issue in ANOTHER repo the user might paste
        $w.ByKey['me/proj#50'].pr = $true
        $e2 = @{ id = 70001; number = 4; repo = 'me/other'; state = 'open'; title = 'other repo'; pr = $false }
        $w.ById[[long]70001] = $e2; $w.ByKey['me/other#4'] = $e2
        return $w
    }
    function script:ConvertTo-ApiShape($e, [bool]$OmitRepo = $false) {
        $o = [ordered]@{ id = $e.id; number = $e.number; state = $e.state; title = $e.title }
        if (-not $OmitRepo) { $o['repository_url'] = "https://api.github.com/repos/$($e.repo)" }
        if ($e.pr) { $o['pull_request'] = @{ url = 'x' } }
        return $o
    }
    function script:Out-Json($obj) { [pscustomobject]@{ Output = @(($obj | ConvertTo-Json -Depth 6 -Compress)); ExitCode = 0; StdErr = '' } }
    function script:Out-Fail($msg) { [pscustomobject]@{ Output = @(); ExitCode = 1; StdErr = $msg } }

    # The fake gh. Implements exactly the three calls the script makes.
    function script:Invoke-FakeGh($w, [string[]]$GhArgs, $StdIn) {
        $path = @($GhArgs | Where-Object { $_ -like 'repos/*' })[0]
        if ($GhArgs -contains 'POST') {
            $w.Posts += , @{ Path = $path; Body = "$StdIn" }
            if ($w.Mode -eq 'post-fails') { return (Out-Fail 'gh: Validation Failed (HTTP 422)') }
            $iid = [long]((("$StdIn" | ConvertFrom-Json).issue_id))
            $key = ($path -replace '^repos/', '' -replace '/dependencies/blocked_by$', '')
            if (-not $w.ById.ContainsKey($iid)) { return (Out-Fail 'gh: Not Found (HTTP 404)') }
            if ($w.Mode -eq 'drop')    { return (Out-Json @{ ok = $true }) }          # 201 but nothing stored
            if ($w.Mode -eq 'misroute') { $iid = 17 }                                  # GitHub links a stranger
            if (-not $w.Links.ContainsKey($key)) { $w.Links[$key] = @() }
            $w.Links[$key] += $iid
            return (Out-Json @{ ok = $true })
        }
        if ($path -match '^repos/([^/]+/[^/]+)/issues/(\d+)/dependencies/blocked_by') {
            $key = "$($Matches[1])/issues/$($Matches[2])"
            $rk  = "$($Matches[1])#$($Matches[2])"
            # A third party links a stranger between two of the script's own calls.
            $w.Reads++
            if ($w.InjectOnRead -gt 0 -and $w.Reads -eq $w.InjectOnRead) {
                if (-not $w.Links.ContainsKey($key)) { $w.Links[$key] = @() }
                $w.Links[$key] += [long]17
            }
            $ids = @($w.Links["$($Matches[1])/issues/$($Matches[2])"])
            $items = @($ids | Where-Object { $_ } | ForEach-Object { ConvertTo-ApiShape $w.ById[[long]$_] ($w.Mode -eq 'no-repo') })
            if ($items.Count -eq 0) { return [pscustomobject]@{ Output = @('[]'); ExitCode = 0; StdErr = '' } }
            return (Out-Json $items)
        }
        if ($path -match '^repos/([^/]+/[^/]+)/issues/(\d+)$') {
            $k = "$($Matches[1])#$($Matches[2])"
            if (-not $w.ByKey.ContainsKey($k)) { return (Out-Fail 'gh: Not Found (HTTP 404)') }
            $shape = ConvertTo-ApiShape $w.ByKey[$k]
            if ($w.Mode -eq 'issue-other-repo')   { $shape['repository_url'] = 'https://api.github.com/repos/x/renamed' }
            if ($w.Mode -eq 'issue-other-number') { $shape['number'] = $shape['number'] + 1 }
            if ($w.Mode -eq 'issue-no-repo')      { $shape.Remove('repository_url') }
            return (Out-Json $shape)
        }
        return (Out-Fail "fake gh: unexpected call $($GhArgs -join ' ')")
    }
    # dependencies/{n} listings keyed the way the fake POST stores them
}

Describe 'ConvertTo-DependencyNumber - what may be a blocker reference' {
    It 'accepts a bare number and #number' {
        ConvertTo-DependencyNumber -Ref '12'  -TargetRepo 'me/proj' | Should -Be 12
        ConvertTo-DependencyNumber -Ref '#12' -TargetRepo 'me/proj' | Should -Be 12
    }
    It 'accepts owner/repo#n and an issue URL ONLY for the target repo' {
        ConvertTo-DependencyNumber -Ref 'me/proj#7' -TargetRepo 'me/proj' | Should -Be 7
        ConvertTo-DependencyNumber -Ref 'https://github.com/me/proj/issues/8' -TargetRepo 'me/proj' | Should -Be 8
    }
    It 'REFUSES another repository, in either form - the accidental case is always cross-repo' {
        { ConvertTo-DependencyNumber -Ref 'jbarnette/johnson#3' -TargetRepo 'me/proj' } | Should -Throw -ExpectedMessage '*OTRO repositorio*'
        { ConvertTo-DependencyNumber -Ref 'https://github.com/x/y/issues/3' -TargetRepo 'me/proj' } | Should -Throw -ExpectedMessage '*OTRO repositorio*'
    }
    It 'rejects junk and zero' {
        foreach ($bad in @('abc', '12abc', '0', '#0', '', 'me/proj', '-3')) {
            { ConvertTo-DependencyNumber -Ref $bad -TargetRepo 'me/proj' } | Should -Throw
        }
    }
}

Describe 'Invoke-BoardDepend - the happy path sends the DATABASE id, never the number' {
    BeforeEach {
        $script:W = New-World
        Mock Invoke-GhRaw { Invoke-FakeGh $script:W $GhArgs $StdIn }
    }
    It 'links, reads back, and reports linked' {
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('17'))
        $r[0].Status | Should -Be 'linked'
        @($script:W.Links['me/proj/issues/40']).Count | Should -Be 1
    }
    It 'POSTs the resolved id (90017), not the number (17) - and the number-as-id stranger is NOT linked' {
        # Number 17 in the target repo has database id 90017; database id 17 belongs to
        # jbarnette/johnson#3. This is the incident, replayed.
        $null = Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('17')
        $script:W.Posts.Count | Should -Be 1
        $script:W.Posts[0].Body | Should -Be '{"issue_id":90017}'
        $script:W.Posts[0].Body | Should -Not -Match '"issue_id":17\b'
        @($script:W.Links['me/proj/issues/40']) | Should -Be @(90017)
        @($script:W.Links['me/proj/issues/40']) | Should -Not -Contain 17
    }
    It 'handles several blockers, comma lists and #-forms, de-duplicating' {
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11,12', '#13', '12'))
        ($r.Status | Sort-Object -Unique) | Should -Be @('linked')
        $r.Count | Should -Be 3
        @($script:W.Links['me/proj/issues/40']).Count | Should -Be 3
    }
    It 'is idempotent: a blocker already linked is reported, not POSTed again' {
        $null = Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11')
        $script:W.Posts.Count | Should -Be 1
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11'))
        $r[0].Status | Should -Be 'already'
        $script:W.Posts.Count | Should -Be 1
    }
    It '-DryRun resolves and validates but writes nothing' {
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11') -DryRun)
        $r[0].Status | Should -Be 'dry-run'
        $script:W.Posts.Count | Should -Be 0
    }
}

Describe 'Invoke-BoardDepend - refuses BEFORE writing anything' {
    BeforeEach {
        $script:W = New-World
        Mock Invoke-GhRaw { Invoke-FakeGh $script:W $GhArgs $StdIn }
    }
    It 'a cross-repo reference blocks the whole batch, even when the other references are fine' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11', 'me/other#4') } | Should -Throw -ExpectedMessage '*OTRO repositorio*'
        $script:W.Posts.Count | Should -Be 0
    }
    It 'refuses a self-dependency' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('40') } | Should -Throw -ExpectedMessage '*a si mismo*'
        $script:W.Posts.Count | Should -Be 0
    }
    It 'refuses a pull request as a blocker' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('50') } | Should -Throw -ExpectedMessage '*pull request*'
        $script:W.Posts.Count | Should -Be 0
    }
    It 'refuses a blocker that does not exist, naming it' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('999') } | Should -Throw -ExpectedMessage '*#999*'
        $script:W.Posts.Count | Should -Be 0
    }
    It 'refuses when the blocked issue itself does not exist' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 998 -BlockedBy @('11') } | Should -Throw
        $script:W.Posts.Count | Should -Be 0
    }
    It 'refuses a missing -Issue or -BlockedBy' {
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 0 -BlockedBy @('11') } | Should -Throw -ExpectedMessage '*-Issue*'
        { Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @(' , ') } | Should -Throw -ExpectedMessage '*-BlockedBy*'
    }
    It 'refuses a malformed -Repo' {
        { Invoke-BoardDepend -Repo 'noslash' -Issue 40 -BlockedBy @('11') } | Should -Throw -ExpectedMessage '*owner/name*'
    }
}

Describe 'Get-DependencyIssue - the resolver checks the answer, not just the status code' {
    BeforeEach {
        $script:W = New-World
        Mock Invoke-GhRaw { Invoke-FakeGh $script:W $GhArgs $StdIn }
    }
    It 'returns the database id, number and repo for a real issue' {
        $e = Get-DependencyIssue -Repo 'me/proj' -Number 17
        $e.id | Should -Be 90017
        $e.number | Should -Be 17
        $e.repo | Should -Be 'me/proj'
    }
    It 'refuses an answer that resolves to a different repository' {
        $script:W.Mode = 'issue-other-repo'
        { Get-DependencyIssue -Repo 'me/proj' -Number 17 } | Should -Throw -ExpectedMessage '*resuelve a x/renamed*'
    }
    It 'refuses an answer for a different issue number' {
        $script:W.Mode = 'issue-other-number'
        { Get-DependencyIssue -Repo 'me/proj' -Number 17 } | Should -Throw -ExpectedMessage '*devolvio el issue #18*'
    }
    It 'refuses an answer that does not say which repository it belongs to' {
        $script:W.Mode = 'issue-no-repo'
        { Get-DependencyIssue -Repo 'me/proj' -Number 17 } | Should -Throw -ExpectedMessage '*No puedo comprobar*'
    }
}

Describe 'Get-BlockedByList - a full page cannot be verified' {
    It 'fails on 100 or more blockers instead of guessing about a second page' {
        Mock Invoke-GhRaw {
            $items = 1..100 | ForEach-Object { @{ id = 1000 + $_; number = $_; state = 'open'; title = 't'; repository_url = 'https://api.github.com/repos/me/proj' } }
            [pscustomobject]@{ Output = @(($items | ConvertTo-Json -Depth 4 -Compress)); ExitCode = 0; StdErr = '' }
        }
        { Get-BlockedByList -Repo 'me/proj' -Issue 40 } | Should -Throw -ExpectedMessage '*100 o mas*'
    }
    It 'returns the entries (with repository) below the limit' {
        Mock Invoke-GhRaw {
            [pscustomobject]@{ Output = @('[{"id":1001,"number":7,"state":"open","title":"t","repository_url":"https://api.github.com/repos/me/proj"}]'); ExitCode = 0; StdErr = '' }
        }
        $l = @(Get-BlockedByList -Repo 'me/proj' -Issue 40)
        $l.Count | Should -Be 1
        $l[0].repo | Should -Be 'me/proj'
        $l[0].number | Should -Be 7
    }
}

Describe 'Invoke-BoardDepend - a write that did not do what was asked FAILS LOUDLY' {
    BeforeEach {
        $script:W = New-World
        Mock Invoke-GhRaw { Invoke-FakeGh $script:W $GhArgs $StdIn }
    }
    It 'GitHub links a STRANGER instead: FAILED, and the stranger is named' {
        $script:W.Mode = 'misroute'
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11'))
        $r[0].Status  | Should -Be 'FAILED'
        $r[0].Message | Should -Match 'jbarnette/johnson#3'
    }
    It 'a 201 that stored nothing: FAILED - "the link did not stick"' {
        $script:W.Mode = 'drop'
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11'))
        $r[0].Status  | Should -Be 'FAILED'
        $r[0].Message | Should -Match 'NO quedo'
    }
    It 'an API error on the POST: FAILED with the gh message, not a success' {
        $script:W.Mode = 'post-fails'
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11'))
        $r[0].Status  | Should -Be 'FAILED'
        $r[0].Message | Should -Match '422'
    }
    It 'a read-back that cannot say which repository the blocker is in is NOT trusted' {
        $script:W.Mode = 'no-repo'
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11'))
        $r[0].Status  | Should -Be 'FAILED'
        $r[0].Message | Should -Match 'no puedo comprobar el repositorio'
    }
    It 'a stranger added in the GAP between two blockers fails the batch - it does not become the next baseline' {
        # Reads: 1 = before(A), 2 = after(A), 3 = before(B). The stranger appears just before read 3.
        $script:W.InjectOnRead = 3
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11', '12'))
        $r[0].Status | Should -Be 'linked'
        $r[1].Status | Should -Be 'FAILED'
        $r[1].Message | Should -Match 'entre dos escrituras'
        $r[1].Message | Should -Match 'jbarnette/johnson#3'
        $script:W.Posts.Count | Should -Be 1 -Because 'nothing more is written once an unrequested link is seen'
    }
    It 'the gap check also stops the blockers after the failing one' {
        $script:W.InjectOnRead = 3
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11', '12', '13'))
        @($r.Status) | Should -Be @('linked', 'FAILED', 'skipped')
    }
    It 'links THIS invocation made do not count as strangers on the next read' {
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11', '12', '13'))
        @($r.Status | Sort-Object -Unique) | Should -Be @('linked')
    }
    It 'stops at the first failure: later blockers are skipped, not written' {
        $script:W.Mode = 'misroute'
        $r = @(Invoke-BoardDepend -Repo 'me/proj' -Issue 40 -BlockedBy @('11', '12', '13'))
        $r[0].Status | Should -Be 'FAILED'
        @($r[1..2].Status | Sort-Object -Unique) | Should -Be @('skipped')
        $script:W.Posts.Count | Should -Be 1
    }
}

Describe 'Test-DependencyLanded - the verifier on its own' {
    BeforeAll {
        function script:E($id, $n, $repo) { [pscustomobject]@{ id = $id; number = $n; repo = $repo; state = 'open'; title = 't'; isPr = $false } }
        $script:T = script:E 90011 11 'me/proj'
    }
    It 'ok when exactly the target appeared' {
        (Test-DependencyLanded -Before @() -After @((script:E 90011 11 'me/proj')) -Target $script:T).ok | Should -BeTrue
    }
    It 'not ok when the target is missing' {
        (Test-DependencyLanded -Before @() -After @() -Target $script:T).ok | Should -BeFalse
    }
    It 'not ok when the target appeared TOGETHER with something unrequested' {
        $r = Test-DependencyLanded -Before @() -After @((script:E 90011 11 'me/proj'), (script:E 17 3 'jbarnette/johnson')) -Target $script:T
        $r.ok | Should -BeFalse
        @($r.strangers).Count | Should -Be 1
    }
    It 'not ok when the entry with the target id names a different repo or number' {
        (Test-DependencyLanded -Before @() -After @((script:E 90011 11 'x/y')) -Target $script:T).ok | Should -BeFalse
        (Test-DependencyLanded -Before @() -After @((script:E 90011 99 'me/proj')) -Target $script:T).ok | Should -BeFalse
    }
    It 'pre-existing links are not strangers' {
        $r = Test-DependencyLanded -Before @((script:E 90012 12 'me/proj')) -After @((script:E 90012 12 'me/proj'), (script:E 90011 11 'me/proj')) -Target $script:T
        $r.ok | Should -BeTrue
    }
}

Describe 'Board-Depend.ps1 wiring' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:ScriptPath -Raw }
    It 'sends the resolved id in the body, never a raw number' {
        $script:Src | Should -Match ([regex]::Escape("'{`"issue_id`":' + ") + '\$t\.id')
    }
    It 'goes through Invoke-Gh - no raw gh calls' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errs)
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'gh' }, $true)).Count | Should -Be 0
    }
    It 'takes its identity from the resolver (brake-armed runs get the agent identity)' {
        $script:Src | Should -Match 'Get-GhTokenForContext[^\n]*-ExplicitVar'
        $script:Src | Should -Match 'ABIOS_TOKENVAR_DOTSOURCE'
    }
    It 'exits 1 when any link failed' {
        $script:Src | Should -Match "(?s)Status -eq 'FAILED'.*exit 1"
    }
}
