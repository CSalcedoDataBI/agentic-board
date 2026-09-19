#Requires -Modules Pester
<#  Tests for the reviewer liveness probe behind the review gate's way out (#537).

    The gate exits 2 ("GATE SIN REVISAR") and used to recommend the external reviewer
    unconditionally. Both external CLIs can be dead at once - Gemini fails at auth and still
    exits 0 - and then the only exit left is -AllowUnreviewed, the escape hatch the gate exists to
    discourage. These tests pin: a dead reviewer is never recommended, exit 0 is not a verdict, and
    "nothing answered" is said plainly instead of naming a dead reviewer.

    The probe is driven for real against stand-in executables (a .cmd on Windows, a sh script
    elsewhere) put on PATH - the classification, the installed check, the parallel jobs and the
    deadline all run for real; only the vendor CLI is replaced.  #>

BeforeAll {
    $script:ScriptDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
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

    function script:Entry { param([string]$Name, [string]$Cmd) [pscustomobject]@{ Name = $Name; Command = $Cmd; ProbeArgs = @('x') } }
}
AfterAll {
    $env:PATH = $script:OldPath
    Remove-Item -LiteralPath $script:Bin -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ReviewerProbeStatus - exit 0 is not a verdict (#537)' {
    It 'Gemini: an auth error printed on exit 0 is NOT a live reviewer' {
        # Verbatim shape from the issue. A caller that only read the exit code called this success.
        $txt = "IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals (reasonCode: UNSUPPORTED_CLIENT, tierId: free-tier)"
        Get-ReviewerProbeStatus -ExitCode 0 -Output $txt | Should -Be 'unsupported'
    }
    It 'Gemini: refusing an untrusted directory is not alive either, even on exit 0' {
        Get-ReviewerProbeStatus -ExitCode 0 -Output 'Gemini CLI is not running in a trusted directory' | Should -Be 'untrusted'
    }
    It 'exit 0 with an auth error in the text is auth, not ok' {
        Get-ReviewerProbeStatus -ExitCode 0 -Output 'Not logged in. Run login first.' | Should -Be 'auth'
    }
    It 'exit 0 with a quota error in the text is no-quota, not ok' {
        Get-ReviewerProbeStatus -ExitCode 0 -Output 'Error 429: quota exceeded' | Should -Be 'no-quota'
    }
    It 'exit 0 with NO output is no-output - a reviewer that produced nothing is not evidence of a reviewer' {
        Get-ReviewerProbeStatus -ExitCode 0 -Output '' | Should -Be 'no-output'
        Get-ReviewerProbeStatus -ExitCode 0 -Output "  `r`n " | Should -Be 'no-output'
    }
    It 'a non-zero exit with no known cause is a plain error' {
        Get-ReviewerProbeStatus -ExitCode 2 -Output 'something exploded' | Should -Be 'error'
    }
    It 'exit 0 that answered is ok' {
        Get-ReviewerProbeStatus -ExitCode 0 -Output 'OK' | Should -Be 'ok'
    }
    It "codex's logged-in banner is ok - the word 'authenticated' in a success line must not read as a failure" {
        Get-ReviewerProbeStatus -ExitCode 0 -Output 'Logged in using ChatGPT (authenticated)' | Should -Be 'ok'
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
    It 'reports a working CLI as ok, a retired one as unsupported (exit 0!), and a silent one as no-output' {
        $roster = @((Entry 'alive' 'rr-alive'), (Entry 'dead' 'rr-authdead'), (Entry 'silent' 'rr-silent'))
        $res = @(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 60)
        ($res | Where-Object Name -eq 'alive').Status  | Should -Be 'ok'
        ($res | Where-Object Name -eq 'dead').Status   | Should -Be 'unsupported'
        ($res | Where-Object Name -eq 'silent').Status | Should -Be 'no-output'
    }
    It 'a crashing CLI is an error' {
        (@(Invoke-ReviewerProbes -Roster @(Entry 'crash' 'rr-crash') -TimeoutSec 60))[0].Status | Should -Be 'error'
    }
    It 'a CLI that is not on PATH is not-installed, without running anything' {
        $res = @(Invoke-ReviewerProbes -Roster @(Entry 'ghost' 'rr-does-not-exist-anywhere') -TimeoutSec 60)
        $res[0].Status | Should -Be 'not-installed'
        $res[0].Detail | Should -Match 'PATH'
    }
    It 'a CLI that outlives the shared deadline is reported as timeout, and does not hold the others up' {
        $roster = @((Entry 'slow' 'rr-slow'), (Entry 'alive' 'rr-alive'))
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $res = @(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 3)
        $sw.Stop()
        ($res | Where-Object Name -eq 'slow').Status  | Should -Be 'timeout'
        ($res | Where-Object Name -eq 'alive').Status | Should -Be 'ok'
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
        $res[0].Status | Should -Be 'timeout'
        Start-Sleep -Seconds 6
        Test-Path -LiteralPath $marker | Should -BeFalse -Because 'a probe left running past its deadline would finish its work behind the gate'
    }
    It 'the deadline is SHARED: two hung reviewers cost one timeout, not two' {
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $res = @(Invoke-ReviewerProbes -Roster @((Entry 'slowA' 'rr-slow'), (Entry 'slowB' 'rr-slow2')) -TimeoutSec 2)
        $sw.Stop()
        @($res.Status | Sort-Object -Unique) | Should -Be @('timeout')
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3.6 -Because 'a per-reviewer deadline would take ~4 s here'
    }
    It 'returns one record per roster entry, in roster order' {
        $roster = @((Entry 'b' 'rr-alive'), (Entry 'a' 'rr-does-not-exist-anywhere'), (Entry 'c' 'rr-crash'))
        (@(Invoke-ReviewerProbes -Roster $roster -TimeoutSec 60)).Name | Should -Be @('b', 'a', 'c')
    }
}

Describe 'Get-UnreviewedWayOut - the gate only recommends what is alive (#537)' {
    BeforeAll {
        function script:Live { param([string]$N, [string]$C, [string]$S) [pscustomobject]@{ Name = $N; Command = $C; Status = $S; Detail = '' } }
        function script:Text { param($Lines) (@($Lines | ForEach-Object { $_.Text }) -join "`n") }
    }
    It 'names the reviewers that answered, and points at second-opinion' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'ok'), (Live 'codex' 'codex' 'ok')))
        $t | Should -Match 'antigravity \(agy\)'
        $t | Should -Match 'codex \(codex\)'
        $t | Should -Match 'second-opinion'
        $t | Should -Match '-RecordReview'
    }
    It 'lists a dead reviewer as dead - it is never named as an option' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'auth'), (Live 'codex' 'codex' 'ok')))
        $t | Should -Match 'responden ahora: codex \(codex\)'
        $t | Should -Match 'no responde: antigravity - no esta autenticado'
        $t | Should -Not -Match 'responden ahora:[^\n]*antigravity'
    }
    It 'when NOTHING answers, says so plainly and does not recommend second-opinion' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'unsupported'), (Live 'codex' 'codex' 'not-installed')))
        $t | Should -Match 'NINGUN revisor externo responde'
        $t | Should -Match 'no lo recomiendo'
        $t | Should -Not -Match 'sirve'
        $t | Should -Not -Match 'Usa la skill second-opinion'
    }
    It 'when nothing answers, gives the reason for EACH reviewer and a human way out' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'timeout'), (Live 'codex' 'codex' 'not-installed')))
        $t | Should -Match 'antigravity \(agy\): no respondio a tiempo'
        $t | Should -Match 'codex \(codex\): no esta instalado'
        $t | Should -Match 'Lee el diff tu mismo'
        $t | Should -Match '-RecordReview'
    }
    It 'an exit-0-but-silent reviewer is reported as not alive' {
        $t = Text (Get-UnreviewedWayOut -Liveness @((Live 'antigravity' 'agy' 'no-output')))
        $t | Should -Match 'NINGUN revisor externo responde'
        $t | Should -Match 'no es un revisor vivo'
    }
    It 'when the probe itself could not run, keeps the recommendation but labels it UNVERIFIED' {
        # Saying "nothing is alive" with no evidence would be the same defect turned around.
        $t = Text (Get-UnreviewedWayOut -Liveness $null)
        $t | Should -Match 'no pude comprobar'
        $t | Should -Not -Match 'NINGUN'
    }
    It 'every line carries text and a colour for the gate to print' {
        foreach ($l in (Get-UnreviewedWayOut -Liveness @((Live 'codex' 'codex' 'ok')))) {
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
        $script:Gate | Should -Not -Match 'el revisor externo \(second-opinion\) sirve'
    }
    It 'probes ONLY inside the GATE SIN REVISAR branch, before its exit 2 - never on a normal pass' {
        $probe = $script:Gate.IndexOf('Invoke-ReviewerProbes')
        $sin   = $script:Gate.IndexOf('GATE SIN REVISAR')
        $exit2 = $script:Gate.IndexOf('exit 2', $sin)
        $probe | Should -BeGreaterThan $sin
        $probe | Should -BeLessThan $exit2
        # ... and it is the only call site.
        ([regex]::Matches($script:Gate, 'Invoke-ReviewerProbes')).Count | Should -Be 1
    }
    It 'still exits 2 on that path, and still offers -AllowUnreviewed as the last resort' {
        $sin = $script:Gate.IndexOf('GATE SIN REVISAR')
        $tail = $script:Gate.Substring($sin, [Math]::Min(6000, $script:Gate.Length - $sin))
        $tail | Should -Match 'exit 2'
        $tail | Should -Match '-AllowUnreviewed'
    }
}
