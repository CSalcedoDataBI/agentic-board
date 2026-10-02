<#
.SYNOPSIS
    Which external reviewers can actually run RIGHT NOW (#537).

.DESCRIPTION
    Board-ReviewGate exits 2 ("GATE UNREVIEWED") when CI is green and nobody read the diff. The
    way out it printed named the external reviewer (second-opinion) unconditionally - without
    checking that one could run. Measured on a normal run, both could not: Gemini CLI fails at
    auth (`IneligibleTierError` / `UNSUPPORTED_CLIENT`) and STILL EXITS 0, and with Copilot
    quota-blocked every recommended reviewer was gone. The only exit left was -AllowUnreviewed,
    the very escape hatch the gate exists to discourage - so the tool pushed the user toward the
    bad option.

    This file holds the answer to "who is alive?", in these pieces:

      Get-ReviewerRoster       the reviewers the gate knows how to probe (data, not code)
      Invoke-ReviewerProbes    installed? authenticated? - bounded, parallel, one deadline
      Get-UnreviewedWayOut     the lines the gate prints, built ONLY from what answered

    Two rules the probe keeps, because both were how a dead reviewer looked alive:

      * Exit 0 is not a verdict. The output is classified by the SAME per-CLI rules the fleet
        uses (Resolve-CliProbeOutcome in BoardWork.Adapters.ps1, #770) into the closed set
        OK | AUTH | RATE_LIMIT | QUOTA | CONTEXT_WINDOW | ERROR, and OK needs the CLI's expected
        answer: an exit-0 run that printed nothing, or printed something unrecognised, is ERROR.
        A reviewer that produced no review is not evidence of a reviewer.
      * Never guess. A CLI that is not on PATH is NOT_INSTALLED; a probe that timed out is ERROR
        and its Detail says so. Nothing here assumes a reviewer works because it exists.

    Cost, stated because the antigravity probe is a real one-token model call (~8-10 s): it runs
    ONLY on the unreviewed exit path of the gate, never on a normal pass, and all probes share one
    deadline (default 30 s).

    Pure at load (functions only, no output, no gh): dot-source it. It dot-sources
    BoardWork.Adapters.ps1 (functions only too) for the probe classifier.
      . (Join-Path $PSScriptRoot 'Get-ReviewerRoster.ps1')

    ROSTER SCOPE. Antigravity (`agy`) and Codex are the two external reviewers second-opinion
    drives today. Gemini CLI is deliberately absent - Google retired its individual-account auth
    on 2026-06-18 and it can never answer again. Cursor's agent CLI is not listed because its
    headless flags were not verified against a real install; the roster is data, so adding it is
    one entry plus its probe once someone has measured it.
#>

# The probe classifier and its closed code set live with the fleet adapters (#770), so a
# reviewer verdict here and a fleet verdict there cannot disagree about the same CLI output.
. (Join-Path $PSScriptRoot 'BoardWork.Adapters.ps1')

# The reviewers the gate can probe. Command = the executable that must be on PATH; ProbeArgs = the
# cheapest invocation that exercises AUTH (not just `--version`, which passes for a logged-out
# CLI). The probes match the ones /board work -Fleet already uses, so a verdict here and there
# cannot disagree about the same CLI.
#
# This is a COPY of the command + probe arguments in Get-CliAdapters (BoardWork.Adapters.ps1): there
# they live inside each adapter's Probe scriptblock, which runs the CLI through a background job,
# while the gate needs the bare argv for its own deadline-bounded processes. It is kept honest by a
# test that reads the fleet's definition and fails when the two differ -
# Get-ReviewerRoster.Tests.ps1, "The roster agrees with the fleet adapters". The output of both is
# classified by the same adapter rules (Name = the adapter name).
function Get-ReviewerRoster {
    return @(
        [pscustomobject]@{
            Name      = 'antigravity'
            Command   = 'agy'
            # Auth/quota only, and the same probe /board work -Fleet uses. No permission bypass
            # (#761): a one-token reply calls no tool, so the flag never changed its verdict.
            ProbeArgs = @('-p', 'reply OK')
        }
        [pscustomobject]@{
            Name      = 'codex'
            Command   = 'codex'
            # An auth check that reads no stdin and calls no model (~2.6 s); `codex exec` as a
            # probe took ~19 s and blocks on stdin.
            ProbeArgs = @('login', 'status')
        }
    )
}

# Classify one probe run of reviewer $Cli into { Code; Reason } with that CLI's own fleet rules
# (#770). The OUTPUT is read before the exit code - Gemini printed an auth error and exited 0, and
# a generic "exit 0 => alive" shortcut is precisely the bug this file exists to remove. Pure.
function Get-ReviewerProbeOutcome {
    param([string]$Cli, [int]$ExitCode, [string]$Output)
    Resolve-CliProbeOutcome -Cli $Cli -ExitCode $ExitCode -Output $Output
}

# Quote one argument for a Windows command line (ProcessStartInfo.Arguments is a single string on
# Windows PowerShell 5.1, which has no ArgumentList). Only the roster's own fixed arguments pass
# through here, but a space or a quote in one must not split or break it.
function ConvertTo-ReviewerArg {
    param([string]$Arg)
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '"', '\"') + '"'
}

# Kill a probe process AND its children. Killing only the launcher would leave a `.cmd` shim's real
# child (node, ping, the vendor binary) running past the deadline - and holding our stdout open.
function Stop-ReviewerProcess {
    param([System.Diagnostics.Process]$Process)
    try {
        if ($Process.HasExited) { return }
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $Process.Kill($true)          # whole tree
        } else {
            & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null   # Windows PowerShell 5.1
        }
    } catch { }
}

# The process seam: start every probe, then wait for each until ONE shared deadline. Separate so
# the tests drive the real classification, the real installed check and the real deadline against
# a stand-in executable, with no model call.
#
# Not Start-Job: Remove-Job -Force on a job whose child is still running BLOCKS until that child
# exits, so a hung CLI held the gate for as long as it liked - the deadline was decorative (caught
# by the test that puts a slow stand-in against a 3 s budget). Owning the process lets a timeout
# actually kill it.
#
# Returns one record per roster entry, in roster order:
#   @{ Name; Command; Status; Detail }
# where Status is a probe code (Get-CliProbeCodes) or NOT_INSTALLED, and Detail says why a
# non-OK reviewer is not answering. A roster entry may name the adapter whose rules classify it
# in `Cli`; it defaults to its Name.
function Invoke-ReviewerProbes {
    param(
        [Parameter(Mandatory)]$Roster,
        [int]$TimeoutSec = 30
    )
    $results = [ordered]@{}
    $procs   = @{}
    foreach ($r in @($Roster)) {
        # Application only: a `.ps1` shim (npm ships one beside the `.cmd`) cannot be started as a
        # process, and the shim that CAN be is what `codex` resolves to in a normal terminal.
        $cmd = Get-Command $r.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) {
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = 'NOT_INSTALLED'; Detail = "$($r.Command) is not on the PATH" }
            continue
        }
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $cmd.Source
            $psi.Arguments              = (@($r.ProbeArgs) | ForEach-Object { ConvertTo-ReviewerArg $_ }) -join ' '
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            # EOF on stdin: some CLIs read it even with a prompt argument and would wait forever.
            $p.StandardInput.Close()
            $procs[$r.Name] = @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
        } catch {
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = 'ERROR'; Detail = "could not launch it: $($_.Exception.Message)" }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    foreach ($r in @($Roster)) {
        if (-not $procs.ContainsKey($r.Name)) { continue }
        $e = $procs[$r.Name]
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        # Two things must finish inside the deadline: the process, AND the streams we read from it.
        # NOT the parameterless WaitForExit(): it also waits for EOF on the redirected pipes, and a
        # launcher that exits while a child it started still holds them would block it past the
        # deadline (review round 1). The readers are ordinary tasks, so they get the remaining budget.
        $done = $false
        if ($e.P.WaitForExit($left)) {
            $left2 = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $tasks = [System.Threading.Tasks.Task[]]@($e.Out, $e.Err)
            $done  = [System.Threading.Tasks.Task]::WaitAll($tasks, $left2)
        }
        if ($done) {
            # stderr first in the text: the auth error the issue quotes goes there, and the
            # classifier reads the whole thing.
            $text = "$($e.Err.Result)`n$($e.Out.Result)"
            $cli  = if ($r.PSObject.Properties['Cli'] -and $r.Cli) { $r.Cli } else { $r.Name }
            $o    = Get-ReviewerProbeOutcome -Cli $cli -ExitCode $e.P.ExitCode -Output $text
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = $o.Code; Detail = $(if ($o.Code -ceq 'OK') { '' } else { $o.Reason }) }
        } else {
            # A timeout is not a seventh probe code: it is ERROR, and the Detail says what happened.
            Stop-ReviewerProcess -Process $e.P
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = 'ERROR'; Detail = "did not answer within ${TimeoutSec}s" }
        }
        $e.P.Dispose()
    }
    return @($Roster | ForEach-Object { $results[$_.Name] })
}

# Plain-language reason for a non-OK status. The probe's Detail is the precise reason (the
# adapter rule that matched, the timeout, the missing PATH entry) and wins when present; the
# code alone is the fallback. Pure.
function Get-ReviewerStatusText {
    param([string]$Status, [string]$Detail)
    if ($Detail) { return $Detail }
    switch -CaseSensitive ($Status) {
        'NOT_INSTALLED'  { 'is not installed' }
        'AUTH'           { 'is not authenticated' }
        'QUOTA'          { 'out of quota' }
        'RATE_LIMIT'     { 'rate limited - retry later' }
        'CONTEXT_WINDOW' { 'the prompt does not fit the model context window' }
        'ERROR'          { 'failed to run' }
        default          { "status '$Status'" }
    }
}

# The lines the gate prints for way #1 of "GATE UNREVIEWED", built ONLY from what answered.
# Returns an array of @{ Text; Color } (the gate owns Write-Host). Pure.
#
# $Liveness is the output of Invoke-ReviewerProbes, or $null when the probe itself could not run -
# then the old recommendation is kept but labelled UNVERIFIED, because saying "nothing is alive"
# on no evidence would be the same defect turned around.
function Get-UnreviewedWayOut {
    param($Liveness)
    $lines = New-Object System.Collections.Generic.List[object]
    $add = { param($t, $c) $lines.Add([pscustomobject]@{ Text = $t; Color = $c }) }

    if ($null -eq $Liveness) {
        & $add '   1. Get a real review - the external reviewer (second-opinion) works in principle,' 'Cyan'
        & $add '      but I could not check whether any of them answers right now: verify it before counting on it.' 'Cyan'
        & $add '      Record it with -RecordReview -Reviewer <who> -Summary <what they found>.' 'DarkGray'
        return $lines.ToArray()
    }
    $alive = @($Liveness | Where-Object { $_.Status -ceq 'OK' })
    $dead  = @($Liveness | Where-Object { $_.Status -cne 'OK' })

    if ($alive.Count -gt 0) {
        $names = ($alive | ForEach-Object { "$($_.Name) ($($_.Command))" }) -join ', '
        & $add "   1. Get a real review - external reviewer(s) answering right now: $names." 'Cyan'
        & $add '      Use the second-opinion skill with one of them and record it with' 'DarkGray'
        & $add '      -RecordReview -Reviewer <who> -Summary <what they found>.' 'DarkGray'
        foreach ($d in $dead) { & $add ("      (not answering: {0} - {1})" -f $d.Name, (Get-ReviewerStatusText -Status $d.Status -Detail $d.Detail)) 'DarkGray' }
    } else {
        & $add '   1. Get a real review - but NO external reviewer answers right now, so' 'Cyan'
        & $add '      second-opinion cannot run and I do not recommend it:' 'Cyan'
        foreach ($d in $dead) { & $add ("        - {0} ({1}): {2}" -f $d.Name, $d.Command, (Get-ReviewerStatusText -Status $d.Status -Detail $d.Detail)) 'DarkGray' }
        & $add '      Read the diff yourself and record it: -RecordReview -Reviewer <your name> -Summary <what you found>.' 'DarkGray'
    }
    return $lines.ToArray()
}
