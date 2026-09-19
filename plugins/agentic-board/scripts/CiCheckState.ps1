<#
.SYNOPSIS
    Tell "CI failed" from "CI never ran" (#481, part of the not-evaluated evidence state of #475).

.DESCRIPTION
    A red check has at least two unrelated causes, and the review gate used to read both as
    "the code is broken":

      - the run's own code fails a real step      -> a FAILURE: the run must fix it, and the
                                                     gate must keep blocking;
      - CI never executed anything                -> NOT EVALUATED: the workflow ended in
        (startup_failure, or a job that GitHub         startup_failure, or a job was refused
        refused to start - exhausted Actions            before its first step (quota, billing,
        minutes, a spending limit, no runner)          no runner). No code change can turn it
                                                       green, so re-pushing at it only burns
                                                       the run's iteration budget.

    Two independent signals mark a check as never executed, and either one is enough because
    each covers a case the other cannot see:

      1. `state` is STARTUP_FAILURE. GitHub says outright that the workflow never started.
      2. The check failed AND its job ran zero steps (`steps: []`, `runner_id: 0`). This is what
         an exhausted-quota job looks like on the wire - measured on a real run of this owner's
         fb-command-center (a `claude-review` job: conclusion failure, steps [], runner_id 0,
         completed 3 s after it was created). `gh pr checks` reports it as an ordinary `fail`,
         so the bucket alone cannot tell it from a broken build.

    FAIL DIRECTION - the whole point of this file: "never ran" is only ever concluded from
    POSITIVE evidence. A failed check whose job facts could not be read, or whose link is not a
    job URL (an external status context), stays a plain FAILURE. Not knowing must never be
    laundered into "not evaluated", because that state is the one the run is allowed to stop
    retrying on. And "not evaluated" is never a pass: the gate still blocks on it, it only says
    WHY and that pushing again will not help. A real failure next to a never-ran check keeps the
    overall state at `failed` - the gate must not become permissive.

    Pure (no gh, no filesystem): callers fetch the job facts and hand them in. Defines functions
    only, so it is safe to dot-source without a guard.

.EXAMPLE
    . .\CiCheckState.ps1
    Get-CiState -Checks $checks -Parsed $true -JobFacts $facts
#>

# The five states a CI verdict can take (plus 'none' / 'unreadable' for "nothing to judge").
#   passed         - at least one check passed and nothing is red or pending
#   failed         - a real check failed (the case the gate exists for)
#   not-evaluated  - the only red things never executed a step
#   pending        - still running/queued
#   none           - a clean read found no checks at all
#   unreadable     - the read itself failed; never a pass

# The job id out of a check's link ('.../actions/runs/<run>/job/<job>'), or 0 when the link is
# not a GitHub Actions job URL (an external status context, an app check).
function Get-CheckJobId {
    param([AllowNull()][AllowEmptyString()][string]$Link)
    if ("$Link" -match '/actions/runs/\d+/job/(\d+)') { return [long]$Matches[1] }
    return 0
}

<#
    How many steps a job REPORTS, from the job object of `GET /repos/{o}/{r}/actions/jobs/{id}`.
    Returns -1 when the facts cannot be trusted (no object, or no `steps` member at all) - a
    missing array is "I could not tell", which must not read as the same thing as an empty one.

    Deliberately the count of steps PRESENT, not of steps with a recognised conclusion (external
    review): a job GitHub refused to start has `steps: []`, and that emptiness is the only
    fingerprint. A job that started and then crashed can carry steps with a null or unusual
    conclusion; counting only known conclusions would call it "never ran", and that is the
    dangerous direction (it tells a run to stop pushing at a CI that did start).
#>
function Get-JobStepCount {
    param($Job)
    if ($null -eq $Job) { return -1 }
    if (-not ($Job.PSObject.Properties.Name -contains 'steps') -and
        -not (($Job -is [hashtable]) -and $Job.ContainsKey('steps'))) { return -1 }
    return @($Job.steps | Where-Object { $_ }).Count
}

<#
    Did this check's job never execute a single step?

    $JobFacts maps a check's link to @{ stepCount = <int> } as read by the caller; a check
    with no entry (or -1) has unknown facts and is NOT concluded to have never run.
#>
function Test-CheckNeverExecuted {
    param(
        [Parameter(Mandatory)]$Check,
        [hashtable]$JobFacts = @{}
    )
    $state  = "$($Check.state)".Trim().ToUpperInvariant()
    if ($state -eq 'STARTUP_FAILURE') { return $true }
    # Job facts only ever reclassify an outright FAILURE. A cancelled job (a newer push
    # superseded it) is not "CI never ran", and a pending one has not settled.
    if ("$($Check.bucket)" -ne 'fail') { return $false }
    $link = "$($Check.link)"
    if (-not $link -or -not $JobFacts -or -not $JobFacts.ContainsKey($link)) { return $false }
    $n = $JobFacts[$link].stepCount
    return ($null -ne $n -and [int]$n -eq 0)
}

<#
    Classify a whole `gh pr checks --json name,bucket,state,link` snapshot.

    Returns @{ state; failed; notEvaluated; pending; passed; retryable }:
      failed        names of checks that really failed (or were cancelled)
      notEvaluated  names of checks that never executed a step
      pending       names still running
      retryable     $true only when pushing again can change the outcome - a real failure. A
                    not-evaluated or pending CI is not retryable: a code change cannot fix it.

    Precedence: unreadable > failed > not-evaluated > pending > passed. `failed` outranks
    `not-evaluated` on purpose - a genuinely failing check must keep the run working on it.
#>
function Get-CiState {
    param(
        $Checks = @(),
        [bool]$Parsed = $false,
        [hashtable]$JobFacts = @{}
    )
    $empty = @{ state = 'unreadable'; failed = @(); notEvaluated = @(); pending = @(); passed = @(); retryable = $false }
    if (-not $Parsed) { return $empty }
    $list = @(@($Checks) | Where-Object { $_ })
    if ($list.Count -eq 0) { $empty.state = 'none'; return $empty }

    $failed = @(); $notEval = @(); $pending = @(); $passed = @()
    foreach ($c in $list) {
        $b = "$($c.bucket)"
        # First: did it never execute? STARTUP_FAILURE settles whatever bucket gh filed it under
        # (an unmapped state can land in 'pending' and would otherwise wait out the whole deadline).
        if     (Test-CheckNeverExecuted -Check $c -JobFacts $JobFacts) { $notEval += "$($c.name)" }
        elseif ($b -in @('fail','cancel'))                              { $failed  += "$($c.name)" }
        elseif ($b -eq 'pending')                                       { $pending += "$($c.name)" }
        elseif ($b -eq 'pass')                                          { $passed  += "$($c.name)" }
        # 'skipping' is settled-ok and counts neither way (mirrors the gate's existing verdict).
        elseif ($b -ne 'skipping')                                      { $failed  += "$($c.name)" }   # an unknown bucket is never a pass
    }
    $state = if     ($failed.Count)  { 'failed' }
             elseif ($notEval.Count) { 'not-evaluated' }
             elseif ($pending.Count) { 'pending' }
             elseif ($passed.Count)  { 'passed' }
             else                    { 'none' }
    return @{
        state        = $state
        failed       = $failed
        notEvaluated = $notEval
        pending      = $pending
        passed       = $passed
        retryable    = [bool]($failed.Count -gt 0)
    }
}
