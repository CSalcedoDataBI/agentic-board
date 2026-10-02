#Requires -Modules Pester
<#  Tests for the reviewer liveness probe behind the review gate's way out (#537).

    The gate exits 2 ("GATE UNREVIEWED") and used to recommend the external reviewer
    unconditionally. Both external CLIs can be dead at once - Gemini fails at auth and still
    exits 0 - and then the only exit left is -AllowUnreviewed, the escape hatch the gate exists to
    discourage. These tests pin: a dead reviewer is never recommended, exit 0 is not a verdict, and
    "nothing answered" is said plainly instead of naming a dead reviewer.

    The probe is driven for real against stand-in executables (a .cmd on Windows, a sh script
    elsewhere) put on PATH - the classification, the installed check, the parallel jobs and the
    deadline all run for real; only the vendor CLI is replaced.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    # Hermetic registry (#772): the roster comes from the shipped preset only, never this
    # machine's ~/.agentic-board/adapters.json or the repo's .agentic-board/adapters.json.
    $env:ABIOS_ADAPTERS_USER_FILE = Join-Path $TestDrive 'no-user-adapters.json'
    $env:ABIOS_ADAPTERS_REPO_FILE = Join-Path $TestDrive 'no-repo-adapters.json'
    . (Join-Path $script:ScriptDir 'Get-ReviewerRoster.ps1')

    $script:Bin = Join-Path ([System.IO.Path]::GetTempPath()) ('rr-bin-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null

    # A stand-in CLI: prints $Text, optionally sleeps, exits $Code.
    function script:New-StandInCli {
        param([string]$Name, [string]$Text = '', [int]$Code = 0, [int]$SleepSec = 0)
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            $lines = @('@echo off')
            if ($SleepSec) { $lines += "ping -n $($SleepSec + 1) 127.0.0.1 >nul" }
            if ($Text)     { $lines += "echo $Text" }
            $lines += "exit /b $Code"
            Set-Content -LiteralPath (Join-Path $script:Bin "$Name.cmd") -Value $lines -Encoding ASCII
        } else {
            $path  = Join-Path $script:Bin $Name
            $lines = @('#!/bin/sh')
            if ($SleepSec) { $lines += "sleep $SleepSec" }
            if ($Text)     { $lines += "echo '$Text'" }
            $lines += "exit $Code"
            Set-Content -LiteralPath $path -Value $lines
            chmod +x $path
        }
    }
    $script:OldPath = $env:PATH
    $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $env:PATH

    New-StandInCli -Name 'rr-alive'  -Text 'OK'
    New-StandInCli -Name 'rr-authdead' -Text 'IneligibleTierError: This client is no longer supported' -Code 0
    New-StandInCli -Name 'rr-silent' -Text '' -Code 0
    New-StandInCli -Name 'rr-crash'  -Text 'boom' -Code 3
    New-StandInCli -Name 'rr-slow'   -Text 'OK' -SleepSec 8
    New-StandInCli -Name 'rr-slow2'  -Text 'OK' -SleepSec 8

    # Stand-ins are classified with the antigravity adapter's rules (#770): OK = it replied OK.
    function script:Entry { param([string]$Name, [string]$Cmd) [pscustomobject]@{ Name = $Name; Command = $Cmd; ProbeArgs = @('x'); Cli = 'antigravity' } }
}
AfterAll {
    $env:ABIOS_ADAPTERS_USER_FILE = $null
    $env:ABIOS_ADAPTERS_REPO_FILE = $null
    $env:PATH = $script:OldPath
    Remove-Item -LiteralPath $script:Bin -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ReviewerProbeOutcome - exit 0 is not a verdict (#537, #770)' {
    BeforeAll {
        function script:Agy { param([int]$Exit, [string]$Out) (Get-ReviewerProbeOutcome -Cli 'antigravity' -ExitCode $Exit -Output $Out).Code }
    }
    It 'Gemini: an auth error printed on exit 0 is NOT a live reviewer' {
        # Verbatim shape from the issue. A caller that only read the exit code called this success.
        $txt = "IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals (reasonCode: UNSUPPORTED_CLIENT, tierId: free-tier)"
        $o = Get-ReviewerProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output $txt
        $o.Code   | Should -BeExactly 'AUTH'
        $o.Reason | Should -Match 'retired'
    }
    It 'refusing an untrusted directory is not alive either, even on exit 0' {
        $o = Get-ReviewerProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output 'Gemini CLI is not running in a trusted directory'
        $o.Code   | Should -BeExactly 'ERROR'
        $o.Reason | Should -Match 'trusted directory'
    }
    It 'exit 0 with an auth error in the text is AUTH, not OK' {
        Agy 0 'Not logged in. Run login first.' | Should -BeExactly 'AUTH'
    }
    It 'exit 0 with a quota error in the text is QUOTA, not OK' {
        Agy 0 'Error 429: quota exceeded' | Should -BeExactly 'QUOTA'
    }
    It 'exit 0 with NO output is ERROR - a reviewer that produced nothing is not evidence of a reviewer' {
        Agy 0 '' | Should -BeExactly 'ERROR'
        (Get-ReviewerProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output "  `r`n ").Reason | Should -Match 'printed nothing'
    }
    It 'a non-zero exit with no known cause is a plain ERROR' {
        Agy 2 'something exploded' | Should -BeExactly 'ERROR'
    }
    It 'exit 0 that answered is OK' {
        Agy 0 'OK' | Should -BeExactly 'OK'
    }
    It 'a healthy banner that merely mentions quota or carries 401/429 inside an id is still OK' {
        Agy 0 "Quota remaining: 500 requests`nOK" | Should -BeExactly 'OK'
        Agy 0 'session a4012bc9429d ready: OK' | Should -BeExactly 'OK'
        Agy 0 'Logged in. Workspace 401 ready, 429 files indexed. OK' | Should -BeExactly 'OK'
    }
    It 'exit 0 with output that is not the expected answer fails closed to ERROR (#770)' {
        Agy 0 'Quota remaining: 500 requests' | Should -BeExactly 'ERROR'
    }
    It 'real quota / rate-limit / auth statuses are still recognised' {
        Agy 1 'HTTP 429 Too Many Requests' | Should -BeExactly 'RATE_LIMIT'
        Agy 1 'RESOURCE_EXHAUSTED: quota exceeded' | Should -BeExactly 'QUOTA'
        Agy 1 'request failed: status 401' | Should -BeExactly 'AUTH'
    }
    It "codex's logged-in banner is OK - the word 'authenticated' in a success line must not read as a failure" {
        (Get-ReviewerProbeOutcome -Cli 'codex' -ExitCode 0 -Output 'Logged in using ChatGPT (authenticated)').Code | Should -BeExactly 'OK'
    }
}

Describe 'Get-ReviewerRoster' {
    It 'lists antigravity and codex, each with a command and a probe' {
        $r = @(Get-ReviewerRoster)
        ($r.Name | Sort-Object) | Should -Be @('antigravity', 'codex')
        foreach ($e in $r) {
            $e.Command | Should -Not -BeNullOrEmpty
            @($e.ProbeArgs).Count | Should -BeGreaterThan 0
        }
    }
    It 'never lists Gemini CLI - Google retired its individual auth, it can never answer' {
        (@(Get-ReviewerRoster) | ForEach-Object { "$($_.Name) $($_.Command)" }) -join ' ' | Should -Not -Match '(?i)gemini'
    }
}

Describe 'ConvertTo-ReviewerArg - one roster argument stays one argument' {
    It 'leaves a plain argument alone' { ConvertTo-ReviewerArg 'login' | Should -Be 'login' }
    It 'quotes an argument with a space (the antigravity prompt)' { ConvertTo-ReviewerArg 'reply OK' | Should -Be '"reply OK"' }
    It 'escapes an embedded quote' { ConvertTo-ReviewerArg 'a"b c' | Should -Be '"a\"b c"' }
}

Describe 'Invoke-ReviewerProbes - real processes against stand-in CLIs' {
    It 'reports a working CLI as OK, a retired one as AUTH (exit 0!), and a silent one as ERROR' {
        $roster = @((Entry 'alive' 'rr-alive'), (Entry 'dead' 'rr-authdead'), (Entry 'silent' 'rr-silent'))
        $res = @(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 60)
        ($res | Where-Object Name -eq 'alive').Status  | Should -BeExactly 'OK'
        ($res | Where-Object Name -eq 'dead').Status   | Should -BeExactly 'AUTH'
        ($res | Where-Object Name -eq 'dead').Detail   | Should -Match 'retired'
        ($res | Where-Object Name -eq 'silent').Status | Should -BeExactly 'ERROR'
        ($res | Where-Object Name -eq 'silent').Detail | Should -Match 'printed nothing'
    }
    It 'a crashing CLI is ERROR' {
        (@(Invoke-ReviewerProbes -Roster @(Entry 'crash' 'rr-crash') -TimeoutSec 60))[0].Status | Should -BeExactly 'ERROR'
    }
    It 'a CLI that is not on PATH is NOT_INSTALLED, without running anything' {
        $res = @(Invoke-ReviewerProbes -Roster @(Entry 'ghost' 'rr-does-not-exist-anywhere') -TimeoutSec 60)
        $res[0].Status | Should -BeExactly 'NOT_INSTALLED'
        $res[0].Detail | Should -Match 'PATH'
    }
    It 'every status is a probe code or NOT_INSTALLED - nothing free-form (#770)' {
        $roster = @((Entry 'alive' 'rr-alive'), (Entry 'dead' 'rr-authdead'), (Entry 'ghost' 'rr-does-not-exist-anywhere'), (Entry 'crash' 'rr-crash'))
        foreach ($r in @(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 60)) {
            Get-CliAvailabilityStates | Should -Contain $r.Status -Because $r.Name
        }
    }
    It 'a CLI that outlives the shared deadline is reported as timeout, and does not hold the others up' {
        $roster = @((Entry 'slow' 'rr-slow'), (Entry 'alive' 'rr-alive'))
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $res = @(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 3)
        $sw.Stop()
        ($res | Where-Object Name -eq 'slow').Status  | Should -BeExactly 'ERROR'
        ($res | Where-Object Name -eq 'slow').Detail  | Should -Match 'did not answer within'
        ($res | Where-Object Name -eq 'alive').Status | Should -BeExactly 'OK'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 7 -Because 'the deadline is shared, not per reviewer'
    }
    It 'a timed-out CLI is KILLED with its children - the vendor process behind a shim does not keep running' {
        $marker = Join-Path $script:Bin 'rr-marker.txt'
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        # The launcher starts a CHILD that sleeps 5 s and only then writes the marker (an npm .cmd
        # shim in front of node is exactly this shape). Killing just the launcher leaves the child
        # alive and the marker appears; a tree kill at the 2 s deadline means it never does.
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            Set-Content -LiteralPath (Join-Path $script:Bin 'rr-child.cmd') -Encoding ASCII -Value @('@echo off', 'ping -n 6 127.0.0.1 >nul', ('echo done> "{0}"' -f $marker))
            Set-Content -LiteralPath (Join-Path $script:Bin 'rr-marker.cmd') -Encoding ASCII -Value @('@echo off', 'cmd /c ""%~dp0rr-child.cmd""', 'exit /b 0')
        } else {
            Set-Content -LiteralPath (Join-Path $script:Bin 'rr-child.sh') -Value @('#!/bin/sh', 'sleep 5', ("echo done > '{0}'" -f $marker))
            $sh = Join-Path $script:Bin 'rr-marker'
            Set-Content -LiteralPath $sh -Value @('#!/bin/sh', 'sh "$(dirname "$0")/rr-child.sh"', 'exit 0')
            chmod +x $sh
        }
        $res = @(Invoke-ReviewerProbes -Roster @(Entry 'marker' 'rr-marker') -TimeoutSec 2)
        $res[0].Detail | Should -Match 'did not answer within'
        Start-Sleep -Seconds 6
        Test-Path -LiteralPath $marker | Should -BeFalse -Because 'a probe left running past its deadline would finish its work behind the gate'
    }
    It 'a launcher that exits while a CHILD still holds its pipes cannot hold the probe past the deadline' {
        # Windows: `start /b` leaves ping running with our stdout; sh: a backgrounded sleep. The
        # launcher itself exits at once. A parameterless WaitForExit() would block until the child
        # closed the pipe (~9 s) - past a 2 s budget.
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            Set-Content -LiteralPath (Join-Path $script:Bin 'rr-orphan.cmd') -Encoding ASCII -Value @('@echo off', 'start "" /b ping -n 10 127.0.0.1', 'exit /b 0')
        } else {
            $sh = Join-Path $script:Bin 'rr-orphan'
            Set-Content -LiteralPath $sh -Value @('#!/bin/sh', 'sleep 9 &', 'exit 0')
            chmod +x $sh
        }
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $res = @(Invoke-ReviewerProbes -Roster @(Entry 'orphan' 'rr-orphan') -TimeoutSec 2)
        $sw.Stop()
        $res[0].Detail | Should -Match 'did not answer within'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
    It 'the deadline is SHARED: two hung reviewers cost one timeout, not two' {
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $res = @(Invoke-ReviewerProbes -Roster @((Entry 'slowA' 'rr-slow'), (Entry 'slowB' 'rr-slow2')) -TimeoutSec 2)
        $sw.Stop()
        @($res.Detail | ForEach-Object { $_ -match 'did not answer within' } | Sort-Object -Unique) | Should -Be @($true)
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3.6 -Because 'a per-reviewer deadline would take ~4 s here'
    }
    It 'returns one record per roster entry, in roster order' {
        $roster = @((Entry 'b' 'rr-alive'), (Entry 'a' 'rr-does-not-exist-anywhere'), (Entry 'c' 'rr-crash'))
        (@(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 60)).Name | Should -Be @('b', 'a', 'c')
    }
}

Describe 'Get-UnreviewedWayOut - the gate only recommends what is alive (#537)' {
    BeforeAll {
        function script:Live { param([string]$N, [string]$C, [string]$S, [string]$D = '') [pscustomobject]@{ Name = $N; Command = $C; Status = $S; Detail = $D } }
        function script:Text { param($Lines) (@($Lines | ForEach-Object { $_.Text }) -join "`n") }
    }
    It 'names the reviewers that answered, and points at second-opinion' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'OK'), (Live 'codex' 'codex' 'OK')))
        $t | Should -Match 'antigravity \(agy\)'
        $t | Should -Match 'codex \(codex\)'
        $t | Should -Match 'second-opinion'
        $t | Should -Match '-RecordReview'
    }
    It 'lists a dead reviewer as dead - it is never named as an option' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'AUTH'), (Live 'codex' 'codex' 'OK')))
        $t | Should -Match 'answering right now: codex \(codex\)'
        $t | Should -Match 'not answering: antigravity - is not authenticated'
        $t | Should -Not -Match 'answering right now:[^\n]*antigravity'
    }
    It 'when NOTHING answers, says so plainly and does not recommend second-opinion' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'AUTH' 'the provider retired this client'), (Live 'codex' 'codex' 'NOT_INSTALLED')))
        $t | Should -Match 'NO external reviewer answers'
        $t | Should -Match 'I do not recommend it'
        $t | Should -Not -Match 'works in principle'
        $t | Should -Not -Match 'Use the second-opinion skill'
    }
    It 'when nothing answers, gives the reason for EACH reviewer and a human way out' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'ERROR' 'did not answer within 30s'), (Live 'codex' 'codex' 'NOT_INSTALLED')))
        $t | Should -Match 'antigravity \(agy\): did not answer within 30s'
        $t | Should -Match 'codex \(codex\): is not installed'
        $t | Should -Match 'Read the diff yourself'
        $t | Should -Match '-RecordReview'
    }
    It 'an exit-0-but-silent reviewer is reported as not alive' {
        $o = Get-ReviewerProbeOutcome -Cli 'antigravity' -ExitCode 0 -Output ''
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' $o.Code $o.Reason)))
        $t | Should -Match 'NO external reviewer answers'
        $t | Should -Match 'printed nothing'
    }
    It 'an old free-form ok is not OK - the reviewer is reported as not answering (#770)' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'codex' 'codex' 'ok')))
        $t | Should -Match 'NO external reviewer answers'
    }
    It 'when the probe itself could not run, keeps the recommendation but labels it UNVERIFIED' {
        # Saying "nothing is alive" with no evidence would be the same defect turned around.
        $t = Text (Get-UnreviewedWayOut -Liveness $null)
        $t | Should -Match 'could not check'
        $t | Should -Not -MatchExactly 'NO external'
    }
    It 'every line carries text and a colour for the gate to print' {
        $ls = @(Get-UnreviewedWayOut -Liveness @((Live 'codex' 'codex' 'OK')))
        $ls.Count | Should -BeGreaterThan 0 -Because 'an empty result would make the loop below pass vacuously'
        foreach ($l in $ls) {
            $l.Text  | Should -Not -BeNullOrEmpty
            $l.Color | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Board-ReviewGate is wired to the probe, and the verdict is untouched (#537)' {
    BeforeAll {
        $script:Gate = Get-Content -LiteralPath (Join-Path $script:ScriptDir 'Board-ReviewGate.ps1') -Raw
    }
    It 'loads the roster and probes on the unreviewed path' {
        $script:Gate | Should -Match "Get-ReviewerRoster\.ps1"
        $script:Gate | Should -Match 'Invoke-ReviewerProbes'
        $script:Gate | Should -Match 'Get-UnreviewedWayOut'
    }
    It 'no longer recommends the external reviewer unconditionally' {
        $script:Gate | Should -Not -Match 'the external reviewer \(second-opinion\) works'
    }
    It 'probes ONLY inside the GATE UNREVIEWED branch, before its exit 2 - never on a normal pass' {
        $probe = $script:Gate.IndexOf('Invoke-ReviewerProbes')
        $sin   = $script:Gate.IndexOf('GATE UNREVIEWED')
        $exit2 = $script:Gate.IndexOf('exit 2', $sin)
        $probe | Should -BeGreaterThan $sin
        $probe | Should -BeLessThan $exit2
        # ... and it is the only call site.
        ([regex]::Matches($script:Gate, 'Invoke-ReviewerProbes')).Count | Should -Be 1
    }
    It 'still exits 2 on that path, and still offers -AllowUnreviewed as the last resort' {
        $sin = $script:Gate.IndexOf('GATE UNREVIEWED')
        $tail = $script:Gate.Substring($sin, [Math]::Min(6000, $script:Gate.Length - $sin))
        $tail | Should -Match 'exit 2'
        $tail | Should -Match '-AllowUnreviewed'
    }
}

Describe 'The roster is derived from the adapter registry, not a copy (#772)' {
    # Before #772 Get-ReviewerRoster repeated two adapters' command + probe arguments and a test read
    # the fleet's Probe scriptblocks to hold the copy equal. The roster now IS the registry's
    # reviewer adapters, so the copy - and the drift it could have - is gone.
    It 'lists exactly the adapters marked reviewer, with their command and their probe argv minus the executable' {
        $reviewers = @(Get-CliAdapters | Where-Object Reviewer)
        $roster    = @(Get-ReviewerRoster)
        ($roster.Name) | Should -Be @($reviewers.Name)
        foreach ($r in $roster) {
            $a = $reviewers | Where-Object Name -eq $r.Name
            $r.Command | Should -Be $a.Command
            $a.ProbeArgs[0] | Should -Be $r.Command -Because "$($r.Name): the probe runs the same executable"
            @($r.ProbeArgs) | Should -Be @($a.ProbeArgs | Select-Object -Skip 1) -Because "$($r.Name): probe arguments"
        }
    }
    It 'keeps the shipped probes: antigravity a one-token reply, codex an auth check with no stdin' {
        $roster = @(Get-ReviewerRoster)
        @(($roster | Where-Object Name -eq 'antigravity').ProbeArgs) | Should -Be @('-p', 'reply OK')
        @(($roster | Where-Object Name -eq 'codex').ProbeArgs)       | Should -Be @('login', 'status')
    }
}
