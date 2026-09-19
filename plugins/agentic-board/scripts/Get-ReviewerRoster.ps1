<#
.SYNOPSIS
    Which external reviewers can actually run RIGHT NOW (#537).

.DESCRIPTION
    Board-ReviewGate exits 2 ("GATE SIN REVISAR") when CI is green and nobody read the diff. The
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

      * Exit 0 is not a verdict. The classifier reads the OUTPUT first (auth / retired client /
        quota / untrusted directory), and an exit-0 run that printed nothing is `no-output`, not
        `ok`. A reviewer that produced no review is not evidence of a reviewer.
      * Never guess. A probe that timed out, or a CLI that is not on PATH, is reported as exactly
        that. Nothing here assumes a reviewer works because it exists.

    Cost, stated because the antigravity probe is a real one-token model call (~8-10 s): it runs
    ONLY on the unreviewed exit path of the gate, never on a normal pass, and all probes share one
    deadline (default 30 s).

    Pure at load (functions only, no output, no gh): dot-source it.
      . (Join-Path $PSScriptRoot 'Get-ReviewerRoster.ps1')

    ROSTER SCOPE. Antigravity (`agy`) and Codex are the two external reviewers second-opinion
    drives today. Gemini CLI is deliberately absent - Google retired its individual-account auth
    on 2026-06-18 and it can never answer again. Cursor's agent CLI is not listed because its
    headless flags were not verified against a real install; the roster is data, so adding it is
    one entry plus its probe once someone has measured it.
#>

# The reviewers the gate can probe. Command = the executable that must be on PATH; ProbeArgs = the
# cheapest invocation that exercises AUTH (not just `--version`, which passes for a logged-out
# CLI). The probes match the ones /board work -Fleet already uses, so a verdict here and there
# cannot disagree about the same CLI.
function Get-ReviewerRoster {
    return @(
        [pscustomobject]@{
            Name      = 'antigravity'
            Command   = 'agy'
            # Same headless flag set second-opinion reviews with: a probe that exercises a
            # different flag set than the real run can green-light a run that then fails.
            ProbeArgs = @('-p', 'reply OK', '--dangerously-skip-permissions')
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

# Classify one probe run into a single status word. Pure.
#
# Order matters and is the point of the function: the OUTPUT is read before the exit code, because
# Gemini printed an auth error and exited 0. A generic "exit 0 => ok" shortcut is precisely the bug
# this file exists to remove.
#   unsupported  the vendor retired this client (IneligibleTierError / UNSUPPORTED_CLIENT)
#   untrusted    refuses headless runs outside a trusted directory
#   no-quota     rate limited / out of quota
#   auth         not logged in
#   error        non-zero exit, none of the above
#   no-output    exit 0 but nothing came back - not evidence of a working reviewer
#   ok           exit 0 and it answered
function Get-ReviewerProbeStatus {
    param([int]$ExitCode, [string]$Output)
    $s = "$Output"
    if ($s -match '(?i)IneligibleTier|UNSUPPORTED_CLIENT|no longer supported')          { return 'unsupported' }
    if ($s -match '(?i)not running in a trusted directory|skip-trust|TRUST_WORKSPACE')  { return 'untrusted' }
    if ($s -match '(?i)rate.?limit|quota|resource.?exhausted|too many requests|\b429\b') { return 'no-quota' }
    if ($s -match '(?i)not logged in|logged out|login required|unauthori[sz]ed|unauthenticated|not authenticated|please (log ?in|sign ?in)|\b401\b') { return 'auth' }
    if ($ExitCode -ne 0)   { return 'error' }
    if (-not $s.Trim())    { return 'no-output' }
    return 'ok'
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
# where Status is a Get-ReviewerProbeStatus word, or `not-installed` / `timeout`.
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
                Status = 'not-installed'; Detail = "$($r.Command) no esta en el PATH" }
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
                Status = 'error'; Detail = "no pude lanzarlo: $($_.Exception.Message)" }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    foreach ($r in @($Roster)) {
        if (-not $procs.ContainsKey($r.Name)) { continue }
        $e = $procs[$r.Name]
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($e.P.WaitForExit($left)) {
            $e.P.WaitForExit()   # flush the async readers
            # stderr first in the text: the auth error the issue quotes goes there, and the
            # classifier reads the whole thing.
            $text = "$($e.Err.Result)`n$($e.Out.Result)"
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = (Get-ReviewerProbeStatus -ExitCode $e.P.ExitCode -Output $text); Detail = '' }
        } else {
            Stop-ReviewerProcess -Process $e.P
            $results[$r.Name] = [pscustomobject]@{ Name = $r.Name; Command = $r.Command
                Status = 'timeout'; Detail = "no respondio en ${TimeoutSec}s" }
        }
        $e.P.Dispose()
    }
    return @($Roster | ForEach-Object { $results[$_.Name] })
}

# Plain-language reason for a non-ok status. Pure.
function Get-ReviewerStatusText {
    param([string]$Status)
    switch ($Status) {
        'not-installed' { 'no esta instalado' }
        'auth'          { 'no esta autenticado' }
        'unsupported'   { 'el proveedor retiro este cliente (ya no puede autenticarse)' }
        'untrusted'     { 'se niega a correr fuera de un directorio de confianza' }
        'no-quota'      { 'sin cupo (rate limit / quota)' }
        'no-output'     { 'salio 0 pero no produjo ninguna salida - eso no es un revisor vivo' }
        'timeout'       { 'no respondio a tiempo' }
        'error'         { 'fallo al ejecutarse' }
        default         { "estado '$Status'" }
    }
}

# The lines the gate prints for way #1 of "GATE SIN REVISAR", built ONLY from what answered.
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
        & $add '   1. Que alguien revise de verdad - el revisor externo (second-opinion) sirve en principio,' 'Cyan'
        & $add '      pero no pude comprobar si alguno responde ahora: verificalo antes de contar con el.' 'Cyan'
        & $add '      Se registra con -RecordReview -Reviewer <quien> -Summary <que encontro>.' 'DarkGray'
        return $lines.ToArray()
    }
    $alive = @($Liveness | Where-Object { $_.Status -eq 'ok' })
    $dead  = @($Liveness | Where-Object { $_.Status -ne 'ok' })

    if ($alive.Count -gt 0) {
        $names = ($alive | ForEach-Object { "$($_.Name) ($($_.Command))" }) -join ', '
        & $add "   1. Que alguien revise de verdad - hay revisor(es) externo(s) que responden ahora: $names." 'Cyan'
        & $add '      Usa la skill second-opinion con uno de ellos y registralo con' 'DarkGray'
        & $add '      -RecordReview -Reviewer <quien> -Summary <que encontro>.' 'DarkGray'
        foreach ($d in $dead) { & $add ("      (no responde: {0} - {1})" -f $d.Name, (Get-ReviewerStatusText -Status $d.Status)) 'DarkGray' }
    } else {
        & $add '   1. Que alguien revise de verdad - pero NINGUN revisor externo responde ahora, asi que' 'Cyan'
        & $add '      second-opinion no puede correr y no lo recomiendo:' 'Cyan'
        foreach ($d in $dead) { & $add ("        - {0} ({1}): {2}" -f $d.Name, $d.Command, (Get-ReviewerStatusText -Status $d.Status)) 'DarkGray' }
        & $add '      Lee el diff tu mismo y registralo: -RecordReview -Reviewer <tu nombre> -Summary <que encontraste>.' 'DarkGray'
    }
    return $lines.ToArray()
}
