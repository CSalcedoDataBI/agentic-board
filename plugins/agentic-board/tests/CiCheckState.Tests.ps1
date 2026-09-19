#Requires -Modules Pester
<#  Tests for "CI failed" vs "CI never ran" (#481).

    The defect: the CI gate read every red check as "the code is broken". On a repo whose Actions
    quota is exhausted (or whose workflow ends in startup_failure) that is false - no step ever
    executed - and a run that loops "push, re-run the gate until green" burns its whole iteration
    budget on a check no code change can move.

    Three layers, each driven for real:
      1. the pure classifier (CiCheckState.ps1), on the job shape MEASURED from a real run of this
         owner's fb-command-center: conclusion failure, steps [], runner_id 0 (the exhausted-quota
         fingerprint), next to an ordinary failing job that executed steps;
      2. Get-ChecksVerdict / Get-FailedCheckJobFacts in Board-ReviewGate.ps1;
      3. the whole gate script in a child pwsh with a scripted `gh`, so the EXIT CODE is proven:
         real failure -> 1 (unchanged), never ran -> 3 (new, still non-zero), healthy CI -> 0.

    The direction that matters most is asserted explicitly: "never ran" is concluded ONLY from
    positive evidence, and a genuinely failing check must keep blocking as a failure. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    . (Join-Path $script:Scripts 'CiCheckState.ps1')

    $env:ABIOS_REVIEWGATE_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Board-ReviewGate.ps1') -Repo 'owner/repo'
    $env:ABIOS_REVIEWGATE_DOTSOURCE = ''

    $script:LinkA = 'https://github.com/o/r/actions/runs/30030030626/job/89284023176'
    $script:LinkB = 'https://github.com/o/r/actions/runs/30030030700/job/89284023999'

    # Measured 2026-09-18 from GET /repos/CSalcedoDataBI/fb-command-center/actions/jobs/89284023176
    # (run 30030030626, a claude-review job): the wire shape of "GitHub refused to start this job".
    $script:JobNeverRan = '{"id":89284023176,"status":"completed","conclusion":"failure","created_at":"2026-07-23T17:35:01Z","started_at":"2026-07-23T17:35:01Z","completed_at":"2026-07-23T17:35:04Z","name":"claude-review","steps":[],"runner_id":0,"runner_name":""}' | ConvertFrom-Json
    # An ordinary red job (shape from csalcedodatabi.com run 34858038219): steps ran, one failed.
    $script:JobBroken = '{"id":104022658049,"status":"completed","conclusion":"failure","name":"lighthouse","runner_id":1000007726,"steps":[{"name":"Set up job","status":"completed","conclusion":"success","number":1},{"name":"Run tests","status":"completed","conclusion":"failure","number":2},{"name":"Post","status":"completed","conclusion":"skipped","number":3}]}' | ConvertFrom-Json

    function script:Chk([string]$name, [string]$bucket, [string]$state = '', [string]$link = '') {
        [pscustomobject]@{ name = $name; bucket = $bucket; state = $state; link = $link }
    }
}

Describe 'Get-CheckJobId / Get-JobStepCount' {
    It 'reads the job id out of an Actions job link' {
        Get-CheckJobId -Link $script:LinkA | Should -Be 89284023176
    }
    It 'returns 0 for a link that is not an Actions job (an external status context)' {
        Get-CheckJobId -Link 'https://ci.example.com/build/123' | Should -Be 0
        Get-CheckJobId -Link '' | Should -Be 0
    }
    It 'counts ZERO executed steps for the measured exhausted-quota job' {
        Get-JobStepCount -Job $script:JobNeverRan | Should -Be 0
    }
    It 'counts the steps PRESENT for an ordinary failing job' {
        Get-JobStepCount -Job $script:JobBroken | Should -Be 3
    }
    It 'a job that started and crashed (steps with a null / unusual conclusion) is NOT zero steps (review round 1)' {
        $crashed = '{"steps":[{"name":"Set up job","status":"in_progress","conclusion":null,"number":1},{"name":"x","status":"completed","conclusion":"action_required","number":2}]}' | ConvertFrom-Json
        Get-JobStepCount -Job $crashed | Should -Be 2
        $facts = @{ $script:LinkA = @{ stepCount = (Get-JobStepCount -Job $crashed) } }
        Test-CheckNeverExecuted -Check (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA) -JobFacts $facts | Should -BeFalse
    }
    It 'returns -1 (cannot tell) when the job object or its steps member is missing - never 0' {
        Get-JobStepCount -Job $null | Should -Be -1
        Get-JobStepCount -Job ([pscustomobject]@{ id = 1; conclusion = 'failure' }) | Should -Be -1
    }
    It 'returns -1 for `steps: null` (a member that exists but says nothing); only an empty ARRAY is zero' {
        Get-JobStepCount -Job ([pscustomobject]@{ id = 1; steps = $null }) | Should -Be -1
        Get-JobStepCount -Job @{ id = 1; steps = $null } | Should -Be -1
        Get-JobStepCount -Job ([pscustomobject]@{ id = 1; steps = @() }) | Should -Be 0
    }
}

Describe 'Test-CheckNeverExecuted - positive evidence only' {
    It 'STARTUP_FAILURE state alone is enough, whatever the bucket' {
        Test-CheckNeverExecuted -Check (script:Chk 'CI' 'fail' 'STARTUP_FAILURE') | Should -BeTrue
        Test-CheckNeverExecuted -Check (script:Chk 'CI' 'pending' 'STARTUP_FAILURE') | Should -BeTrue
    }
    It 'a failed check whose job ran zero steps never executed' {
        $facts = @{ $script:LinkA = @{ stepCount = 0 } }
        Test-CheckNeverExecuted -Check (script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA) -JobFacts $facts | Should -BeTrue
    }
    It 'a failed check whose job ran steps is a real failure' {
        $facts = @{ $script:LinkA = @{ stepCount = 2 } }
        Test-CheckNeverExecuted -Check (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA) -JobFacts $facts | Should -BeFalse
    }
    It 'a failed check with NO job facts stays a failure: not knowing is never "never ran"' {
        Test-CheckNeverExecuted -Check (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA) -JobFacts @{} | Should -BeFalse
        Test-CheckNeverExecuted -Check (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA) | Should -BeFalse
    }
    It 'job facts never reclassify a cancelled or a passing check' {
        $facts = @{ $script:LinkA = @{ stepCount = 0 } }
        Test-CheckNeverExecuted -Check (script:Chk 'a' 'cancel' 'CANCELLED' $script:LinkA) -JobFacts $facts | Should -BeFalse
        Test-CheckNeverExecuted -Check (script:Chk 'a' 'pass' 'SUCCESS' $script:LinkA) -JobFacts $facts | Should -BeFalse
    }
}

Describe 'Get-CiState - the states are distinct' {
    It 'passed: a green check' {
        (Get-CiState -Checks @((script:Chk 'a' 'pass' 'SUCCESS')) -Parsed $true).state | Should -Be 'passed'
    }
    It 'failed: a real failure, and it is retryable (the code has something to fix)' {
        $s = Get-CiState -Checks @((script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true `
                         -JobFacts @{ $script:LinkA = @{ stepCount = 2 } }
        $s.state     | Should -Be 'failed'
        $s.failed    | Should -Contain 'Pester'
        $s.retryable | Should -BeTrue
    }
    It 'not-evaluated: the only red check never ran, and it is NOT retryable' {
        $s = Get-CiState -Checks @((script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true `
                         -JobFacts @{ $script:LinkA = @{ stepCount = 0 } }
        $s.state        | Should -Be 'not-evaluated'
        $s.notEvaluated | Should -Contain 'claude-review'
        $s.retryable    | Should -BeFalse
    }
    It 'a real failure OUTRANKS a never-ran check - the gate must not become permissive' {
        $s = Get-CiState -Checks @(
                (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA),
                (script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkB)) -Parsed $true `
             -JobFacts @{ $script:LinkA = @{ stepCount = 3 }; $script:LinkB = @{ stepCount = 0 } }
        $s.state        | Should -Be 'failed'
        $s.failed       | Should -Contain 'Pester'
        $s.notEvaluated | Should -Contain 'claude-review'
    }
    It 'pending, none and unreadable are their own states - none of them a pass' {
        (Get-CiState -Checks @((script:Chk 'a' 'pending')) -Parsed $true).state | Should -Be 'pending'
        (Get-CiState -Checks @() -Parsed $true).state                           | Should -Be 'none'
        (Get-CiState -Checks @() -Parsed $false).state                          | Should -Be 'unreadable'
    }
    It 'an unknown bucket is never a pass' {
        (Get-CiState -Checks @((script:Chk 'a' 'weird')) -Parsed $true).state | Should -Be 'failed'
    }
}

Describe 'Get-ChecksVerdict - never ran is split from failed, and never becomes Ok (#481)' {
    It 'a healthy CI is untouched: Ok, nothing failed, nothing not-evaluated' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'pass' 'SUCCESS'), (script:Chk 'lint' 'pass' 'SUCCESS')) -Parsed $true
        $v.Ok | Should -BeTrue
        @($v.Failed).Count       | Should -Be 0
        @($v.NotEvaluated).Count | Should -Be 0
    }
    It 'a real failure is Failed and still blocks' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true `
                               -JobFacts @{ $script:LinkA = @{ stepCount = 2 } }
        $v.Ok | Should -BeFalse
        $v.Failed | Should -Contain 'Pester'
        @($v.NotEvaluated).Count | Should -Be 0
    }
    It 'a job that ran zero steps is NotEvaluated, not Failed - and still blocks (Ok stays false)' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true `
                               -JobFacts @{ $script:LinkA = @{ stepCount = 0 } }
        $v.Ok           | Should -BeFalse
        $v.Settled      | Should -BeTrue
        @($v.Failed).Count | Should -Be 0
        $v.NotEvaluated | Should -Contain 'Pester'
    }
    It 'a startup_failure state is NotEvaluated even with no job facts, and even if gh filed it as pending' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'CI' 'pending' 'STARTUP_FAILURE')) -Parsed $true
        $v.NotEvaluated | Should -Contain 'CI'
        $v.Settled      | Should -BeTrue -Because 'a check that can never start must not hold the gate waiting for its deadline'
        $v.Ok           | Should -BeFalse
    }
    It 'without job facts a red check stays Failed (the pre-#481 behaviour)' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true
        $v.Failed | Should -Contain 'Pester'
        @($v.NotEvaluated).Count | Should -Be 0
    }
}

Describe 'Get-ChecksVerdict - a bucket the gate does not recognise fails CLOSED (review thread)' {
    It 'an unknown bucket is neither Failed nor Pending, but is NOT Ok - it is named in Unknown' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'Pester' 'pass' 'SUCCESS'), (script:Chk 'newthing' 'brand_new' 'WEIRD')) -Parsed $true
        $v.Ok      | Should -BeFalse
        $v.Unknown | Should -Contain 'newthing'
        $v.Settled | Should -BeTrue -Because 'waiting will not make an unrecognised state recognisable'
    }
    It 'an empty or missing bucket is unknown too, and a nameless check is still named' {
        $v = Get-ChecksVerdict -Checks @([pscustomobject]@{ name = ''; bucket = '' }, [pscustomobject]@{ name = 'x' }) -Parsed $true
        $v.Ok | Should -BeFalse
        @($v.Unknown).Count | Should -Be 2
        $v.Unknown | Should -Contain '(sin nombre)'
    }
    It 'a bucket with stray whitespace is unknown, never silently recognised-but-uncounted (codex review)' {
        foreach ($b in ' fail ', ' pending ', 'fail ', ' pass') {
            $v = Get-ChecksVerdict -Checks @((script:Chk 'x' $b)) -Parsed $true
            $v.Ok | Should -BeFalse -Because "'$b'"
            $v.Unknown | Should -Contain 'x' -Because "'$b'"
        }
    }
    It 'a never-ran check with an unrecognised bucket is ALSO unknown (so it cannot take the exit-3 path)' {
        $v = Get-ChecksVerdict -Checks @((script:Chk 'CI' 'brand_new' 'STARTUP_FAILURE')) -Parsed $true
        $v.NotEvaluated | Should -Contain 'CI'
        $v.Unknown      | Should -Contain 'CI'
    }
    It 'the five documented buckets are all recognised - none of them lands in Unknown' {
        foreach ($b in 'pass', 'fail', 'pending', 'skipping', 'cancel') {
            @((Get-ChecksVerdict -Checks @((script:Chk 'a' $b)) -Parsed $true).Unknown).Count | Should -Be 0 -Because $b
        }
    }
}

Describe 'Get-FailedCheckJobFacts - reads job facts for failed checks only, fails to "unknown"' {
    BeforeAll {
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        function script:Invoke-Gh {
            param([string[]]$GhArgs, [string]$What, [switch]$Json, [int]$Retries, [switch]$Graphql, [switch]$StdIn)
            $script:Calls.Add(($GhArgs -join ' '))
            if ($env:FAKE_JOB_MODE -eq 'throw') { throw "No pude $What (gh exit 1)" }
            if ($GhArgs -join ' ' -match '/jobs/89284023176$') { return $script:JobNeverRan }
            return $script:JobBroken
        }
    }
    BeforeEach { $script:Calls.Clear(); $env:FAKE_JOB_MODE = '' }
    AfterAll   { $env:FAKE_JOB_MODE = '' }

    It 'fetches the failed check job and records its executed-step count under the check link' {
        $f = Get-FailedCheckJobFacts -Checks @((script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA)) -Repo 'o/r'
        $f[$script:LinkA].stepCount | Should -Be 0
        $script:Calls[0] | Should -Be 'api repos/o/r/actions/jobs/89284023176'
    }
    It 'does NOT fetch anything for passing, pending or cancelled checks, nor for non-job links' {
        $null = Get-FailedCheckJobFacts -Repo 'o/r' -Checks @(
            (script:Chk 'a' 'pass' 'SUCCESS' $script:LinkA),
            (script:Chk 'b' 'pending' '' $script:LinkA),
            (script:Chk 'c' 'cancel' 'CANCELLED' $script:LinkA),
            (script:Chk 'd' 'fail' 'FAILURE' 'https://ci.example.com/build/1'))
        $script:Calls.Count | Should -Be 0
    }
    It 'a failed READ leaves no entry - the check stays a plain failure (never laundered into "never ran")' {
        $env:FAKE_JOB_MODE = 'throw'
        $f = Get-FailedCheckJobFacts -Checks @((script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA)) -Repo 'o/r'
        $f.Count | Should -Be 0
        $v = Get-ChecksVerdict -Checks @((script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA)) -Parsed $true -JobFacts $f
        $v.Failed | Should -Contain 'claude-review'
    }
    It 'end to end on the measured job shapes: never-ran job is NotEvaluated, the broken one is Failed' {
        $checks = @((script:Chk 'claude-review' 'fail' 'FAILURE' $script:LinkA), (script:Chk 'Pester' 'fail' 'FAILURE' $script:LinkB))
        $f = Get-FailedCheckJobFacts -Checks $checks -Repo 'o/r'
        $v = Get-ChecksVerdict -Checks $checks -Parsed $true -JobFacts $f
        $v.NotEvaluated | Should -Contain 'claude-review'
        $v.Failed       | Should -Contain 'Pester'
    }
}

Describe 'Board-ReviewGate.ps1 as a whole - the EXIT CODE distinguishes the three CI states (#481)' {
    BeforeAll {
        $script:Gate = Join-Path $script:Scripts 'Board-ReviewGate.ps1'
        # Runs the real gate in a CHILD pwsh whose `gh` is a scripted function (the seam
        # Invoke-GhRaw exposes), so PATH/env never leak and no network is touched. The scripted gh
        # answers each call shape the gate makes; CI checks and the job come from env vars.
        $script:Fake = @'
function gh {
    # `--json name,bucket` reaches a FUNCTION as an array (a native gh would get "name,bucket"), so
    # re-join array arguments with commas to see what the real executable would see.
    $a = (@($args) | ForEach-Object { if ($_ -is [array]) { $_ -join ',' } else { "$_" } }) -join ' '
    $global:LASTEXITCODE = 0
    if ($a -match '^pr checks \d+ --repo \S+ --json (\S+)') {
        # Like the real gh: only the REQUESTED --json fields come back. Without this the scripted gh
        # would hand over `state`/`link` even if the gate stopped asking for them, and the test
        # could not notice (the mutation "gate asks only name,bucket" survived exactly that way).
        $want = $Matches[1] -split ','
        $rows = @($env:FAKE_CHECKS | ConvertFrom-Json)
        ,@($rows | ForEach-Object { $o = [ordered]@{}; foreach ($k in $want) { if ($_.PSObject.Properties.Name -contains $k) { $o[$k] = $_.$k } }; [pscustomobject]$o }) | ConvertTo-Json -Depth 5 -Compress
        return
    }
    if ($a -match '^api repos/\S+/actions/jobs/(\d+)')       { $env:FAKE_JOB; return }
    if ($a -match '^api graphql') {
        $nodes = @()
        if ($env:FAKE_REVIEWED -eq '1') { $nodes = @(@{ body = '<!-- [abios-review] codex/gpt-5.5 sha=abc123def456abc123def456abc123def456abcd -->'; author = @{ login = 'a-human' } }) }
        @{ data = @{ repository = @{ pullRequest = @{ headRefOid = 'abc123def456abc123def456abc123def456abcd'; reviewDecision = $null
            reviews = @{ nodes = @() }; reviewThreads = @{ nodes = @() }; comments = @{ nodes = $nodes } } } } } | ConvertTo-Json -Depth 10 -Compress
        return
    }
    if ($a -match '^pr view \d+ --repo \S+ --json additions') { '{"additions":3,"deletions":1,"changedFiles":1,"author":{"login":"someone"}}'; return }
    if ($a -match '^pr view \d+ --repo \S+ --json commits')   { '{"commits":[]}'; return }
    if ($a -match 'requested_reviewers')                      { '{"users":[],"requested_reviewers":[]}'; return }
    if ($a -match '/pulls/\d+/files')                          { return }
    if ($a -match '^api user')                                { '{"login":"someone-else"}'; return }
    $global:LASTEXITCODE = 1
    [Console]::Error.WriteLine("fake gh: unexpected call: $a")
}
'@
        function script:Run-Gate {
            param([string]$ChecksJson, [string]$JobJson = '{}', [switch]$Reviewed)
            $env:FAKE_CHECKS   = $ChecksJson
            $env:FAKE_JOB      = $JobJson
            $env:FAKE_REVIEWED = $(if ($Reviewed) { '1' } else { '0' })
            $env:GH_TOKEN      = 'x'
            $file = Join-Path ([System.IO.Path]::GetTempPath()) ("gate-" + [guid]::NewGuid().ToString('N') + '.ps1')
            # Unreviewed runs pass -AllowUnreviewed so the CI verdict alone decides the exit code;
            # -Reviewed runs supply a recorded external review instead and do NOT pass it.
            $allow = if ($Reviewed) { '' } else { '-AllowUnreviewed' }
            $body = $script:Fake + "`n`$env:GH_TOKEN='x'`n& '$($script:Gate)' -Repo o/r -PR 7 $allow -TimeoutMinutes 1 -CiTimeoutMinutes 1`nexit `$LASTEXITCODE`n"
            [System.IO.File]::WriteAllText($file, $body)
            try {
                $out = & pwsh -NoProfile -File $file 2>&1 | Out-String
                return @{ exit = $LASTEXITCODE; out = $out }
            } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
        $script:GoodJob = '{"id":89284023999,"conclusion":"failure","name":"Pester","steps":[{"name":"Run","status":"completed","conclusion":"failure","number":1}]}'
    }
    AfterAll { $env:FAKE_CHECKS = ''; $env:FAKE_JOB = '' }

    It 'HEALTHY CI: green checks -> GATE PASSED, exit 0 (the regression guard for the other direction)' {
        $r = Run-Gate -ChecksJson ('[{"name":"Pester","bucket":"pass","state":"SUCCESS","link":"' + $script:LinkA + '"}]')
        $r.exit | Should -Be 0 -Because $r.out
        $r.out  | Should -Match 'GATE PASSED'
    }
    It 'CI FAILED on a real step -> GATE BLOCKED, exit 1, reported as a failure' {
        $r = Run-Gate -JobJson $script:GoodJob -ChecksJson ('[{"name":"Pester","bucket":"fail","state":"FAILURE","link":"' + $script:LinkB + '"}]')
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Match 'checks fallando'
        $r.out  | Should -Not -Match 'NO SE EVALUO'
    }
    It 'CI NEVER RAN (job with zero steps) -> still blocked, but exit 3 and named "no se evaluo"' {
        $r = Run-Gate -JobJson ($script:JobNeverRan | ConvertTo-Json -Depth 5 -Compress) `
                      -ChecksJson ('[{"name":"Pester","bucket":"fail","state":"FAILURE","link":"' + $script:LinkA + '"}]')
        $r.exit | Should -Be 3 -Because $r.out
        $r.out  | Should -Match 'GATE BLOCKED'
        $r.out  | Should -Match 'NO SE EVALUO'
        $r.out  | Should -Match 'No re-empujes'
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'CI NEVER RAN (startup_failure state) -> exit 3 without needing any job lookup' {
        $r = Run-Gate -ChecksJson '[{"name":"CI","bucket":"fail","state":"STARTUP_FAILURE","link":"https://github.com/o/r/actions/runs/1/job/2"}]'
        $r.exit | Should -Be 3 -Because $r.out
        $r.out  | Should -Match 'NO SE EVALUO'
    }
    It 'a real failure NEXT TO a never-ran check keeps exit 1 - the gate does not become permissive' {
        $checks = '[{"name":"Pester","bucket":"fail","state":"FAILURE","link":"' + $script:LinkB + '"},{"name":"claude-review","bucket":"fail","state":"STARTUP_FAILURE","link":"' + $script:LinkA + '"}]'
        $r = Run-Gate -JobJson $script:GoodJob -ChecksJson $checks
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Match 'checks fallando'
    }
    It 'a REVIEWER job that never ran, with a real recorded review, is still excused exactly as before (#481 must not remove that allowance)' {
        $r = Run-Gate -Reviewed -JobJson ($script:JobNeverRan | ConvertTo-Json -Depth 5 -Compress) `
                      -ChecksJson ('[{"name":"claude-review","bucket":"fail","state":"FAILURE","link":"' + $script:LinkA + '"}]')
        $r.exit | Should -Be 0 -Because $r.out
        $r.out  | Should -Match 'GATE PASSED'
    }
    It 'a reviewer STARTUP_FAILURE that gh filed as PENDING is not excused by a recorded review: exit 3, never newly permitted (review round 1)' {
        # Before #481 this check was "pending" (waited out, then blocked). The reviewer allowance
        # covers red checks; it must not start covering a check that was never red.
        $r = Run-Gate -Reviewed -ChecksJson '[{"name":"claude-review","bucket":"pending","state":"STARTUP_FAILURE","link":"https://github.com/o/r/actions/runs/1/job/2"}]'
        $r.exit | Should -Be 3 -Because $r.out
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'a NON-reviewer job that never ran is NOT excused by a recorded review: exit 3, never a pass' {
        $r = Run-Gate -Reviewed -JobJson ($script:JobNeverRan | ConvertTo-Json -Depth 5 -Compress) `
                      -ChecksJson ('[{"name":"Pester","bucket":"fail","state":"FAILURE","link":"' + $script:LinkA + '"}]')
        $r.exit | Should -Be 3 -Because $r.out
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'a check with a bucket the gate does not recognise BLOCKS (exit 1), named - it is never passed over (review thread)' {
        $r = Run-Gate -ChecksJson '[{"name":"Pester","bucket":"pass","state":"SUCCESS","link":"x"},{"name":"newthing","bucket":"brand_new","state":"WEIRD","link":"y"}]'
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Match 'no reconoce'
        $r.out  | Should -Match 'newthing'
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'an unrecognised REVIEWER check is not excused by a recorded review: still exit 1' {
        $r = Run-Gate -Reviewed -ChecksJson '[{"name":"claude-review","bucket":"brand_new","state":"WEIRD","link":"y"}]'
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'a STARTUP_FAILURE check with an unrecognised bucket is exit 1 (unknown), not the exit-3 never-ran path (codex review)' {
        $r = Run-Gate -ChecksJson '[{"name":"CI","bucket":"brand_new","state":"STARTUP_FAILURE","link":"y"}]'
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Match 'no reconoce'
    }
    It 'a failed REVIEWER check that IS excused (recorded review) must not drag an unrecognised check through with it: exit 1' {
        # The allowance only looks at red names; without an explicit guard it would excuse the
        # reviewer and leave the unknown check unexamined.
        $r = Run-Gate -Reviewed -ChecksJson '[{"name":"claude-review","bucket":"fail","state":"FAILURE","link":"https://github.com/o/r/actions/runs/1/job/2"},{"name":"newthing","bucket":"brand_new","state":"WEIRD","link":"y"}]'
        $r.exit | Should -Be 1 -Because $r.out
        $r.out  | Should -Not -Match 'GATE PASSED'
    }
    It 'an unrecognised bucket next to a never-ran check is exit 1, not 3: there is something the run cannot classify' {
        $r = Run-Gate -ChecksJson '[{"name":"CI","bucket":"fail","state":"STARTUP_FAILURE","link":"https://github.com/o/r/actions/runs/1/job/2"},{"name":"newthing","bucket":"brand_new","state":"WEIRD","link":"y"}]'
        $r.exit | Should -Be 1 -Because $r.out
    }
    It 'an unreadable job read cannot turn a red check into "never ran": exit 1' {
        # FAKE_JOB is not valid JSON -> Invoke-Gh -Json throws -> no facts -> plain failure.
        $r = Run-Gate -JobJson 'not json' -ChecksJson ('[{"name":"Pester","bucket":"fail","state":"FAILURE","link":"' + $script:LinkA + '"}]')
        $r.exit | Should -Be 1 -Because $r.out
    }
}
