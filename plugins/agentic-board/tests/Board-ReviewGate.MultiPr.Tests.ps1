#Requires -Modules Pester
<#  Tests for the multi-PR review gate (#487): -PullRequests / -Issue on Board-ReviewGate.ps1.

    The single-PR gate is safety-sensitive and stays exactly as it was: the multi-PR mode only
    ORCHESTRATES it, running each PR through that same gate as its own process and aggregating the
    exit codes. So the properties that matter, and that these pin, are all about the aggregation:
    it can only ESCALATE (a block is a block, an unreadable PR is never a pass, an empty list is
    never a pass), and the classic `-Repo x -PR n` call still binds and behaves as before. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-ReviewGate.ps1' | Resolve-Path
    $env:ABIOS_REVIEWGATE_DOTSOURCE = '1'
    . $script:Script -Repo 'owner/repo'    # -Repo is Mandatory in the classic set; the guard returns before it is used
    $env:ABIOS_REVIEWGATE_DOTSOURCE = ''

    # Runs Invoke-GateMulti with Invoke-GateChild replaced (the spawn seam); returns { Code; Text; Calls }.
    function Invoke-Multi {
        param([hashtable]$Codes, [string[]]$Specs = @(), [int]$Issue = 0, [string]$DefaultRepo = '', [string]$StateDir = '', $Bound = @{})
        $script:ChildCalls = @()
        Mock Invoke-GateChild {
            $script:ChildCalls += , @($ChildArgs)
            $ref = "$($ChildArgs[1])#$($ChildArgs[3])"
            if ($script:CodeMap.ContainsKey($ref)) { return $script:CodeMap[$ref] }
            return 0
        }
        $script:CodeMap = $Codes
        $out = & { Invoke-GateMulti -Specs $Specs -Issue $Issue -DefaultRepo $DefaultRepo -Bound $Bound -StateDir $StateDir } 6>&1
        [pscustomobject]@{
            Code  = ($out | Where-Object { $_ -is [int] } | Select-Object -Last 1)
            Text  = (($out | Where-Object { $_ -isnot [int] }) | Out-String)
            Calls = @($script:ChildCalls)
        }
    }
}

Describe 'Get-GateVerdictName' {
    It 'keeps the single gate''s exit codes: 0 pass, 1 block, 2 unreviewed, 3 CI not evaluated' {
        Get-GateVerdictName 0 | Should -Be 'pass'
        Get-GateVerdictName 1 | Should -Be 'block'
        Get-GateVerdictName 2 | Should -Be 'unreviewed'
        Get-GateVerdictName 3 | Should -Be 'ci-not-evaluated'
    }
    It 'reads a missing or unexpected code as unknown - never as a pass' {
        Get-GateVerdictName $null | Should -Be 'unknown'
        Get-GateVerdictName ''    | Should -Be 'unknown'
        Get-GateVerdictName 4     | Should -Be 'unknown'
        Get-GateVerdictName -1    | Should -Be 'unknown'
        Get-GateVerdictName 'x'   | Should -Be 'unknown'
        Get-GateVerdictName 137   | Should -Be 'unknown'
    }
}

Describe 'Get-GateRunVerdict' {
    It 'passes only when there is at least one PR and every PR passed' {
        (Get-GateRunVerdict -Verdicts @('pass')).ExitCode | Should -Be 0
        (Get-GateRunVerdict -Verdicts @('pass', 'pass', 'pass')).ExitCode | Should -Be 0
    }
    It 'is never a pass for an empty list' {
        (Get-GateRunVerdict -Verdicts @()).ExitCode | Should -Be 4
    }
    It 'any block is a block, whatever else there is' {
        (Get-GateRunVerdict -Verdicts @('pass', 'block', 'pass')).ExitCode | Should -Be 1
        (Get-GateRunVerdict -Verdicts @('unknown', 'block')).ExitCode | Should -Be 1
        (Get-GateRunVerdict -Verdicts @('unreviewed', 'ci-not-evaluated', 'block')).ExitCode | Should -Be 1
    }
    It 'an unreadable PR makes the run unknown (4), never a pass' {
        (Get-GateRunVerdict -Verdicts @('pass', 'unknown')).ExitCode | Should -Be 4
        (Get-GateRunVerdict -Verdicts @('unknown', 'ci-not-evaluated')).ExitCode | Should -Be 4
    }
    It 'ranks CI-not-evaluated (3) above unreviewed (2), and neither is a pass' {
        (Get-GateRunVerdict -Verdicts @('pass', 'unreviewed', 'ci-not-evaluated')).ExitCode | Should -Be 3
        (Get-GateRunVerdict -Verdicts @('pass', 'unreviewed')).ExitCode | Should -Be 2
    }
    It 'an unrecognised verdict name is never a pass' {
        (Get-GateRunVerdict -Verdicts @('pass', 'weird')).ExitCode | Should -Be 4
    }
}

Describe 'Resolve-GatePullRequest' {
    It 'reads owner/name#n, a PR url, and a bare number only when a default repo is known' {
        (Resolve-GatePullRequest 'o/a#5').Repo | Should -Be 'o/a'
        (Resolve-GatePullRequest 'https://github.com/o/a/pull/7').Number | Should -Be 7
        (Resolve-GatePullRequest '9' -DefaultRepo 'o/x').Repo | Should -Be 'o/x'
        Resolve-GatePullRequest '9' | Should -BeNullOrEmpty
        Resolve-GatePullRequest '0' -DefaultRepo 'o/x' | Should -BeNullOrEmpty
        Resolve-GatePullRequest 'nonsense' -DefaultRepo 'o/x' | Should -BeNullOrEmpty
    }
}

Describe 'Get-GateChildArgs' {
    It 'names the repo and PR and forwards nothing the caller did not pass' {
        (Get-GateChildArgs -Repo 'o/a' -Number 5 -Bound @{}) | Should -Be @('-Repo', 'o/a', '-PR', '5')
    }
    It 'forwards the caller''s gate switches so each PR is judged by the same rules' {
        $a = Get-GateChildArgs -Repo 'o/a' -Number 5 -Bound @{ TimeoutMinutes = 9; RequireIndependentReviewer = [switch]$true; AllowUnreviewed = [switch]$true; TokenVar = 'X_TOKEN' }
        ($a -join ' ') | Should -Match '-TimeoutMinutes 9'
        ($a -join ' ') | Should -Match '-TokenVar X_TOKEN'
        $a | Should -Contain '-RequireIndependentReviewer'
        $a | Should -Contain '-AllowUnreviewed'
    }
    It 'works with a real $PSBoundParameters dictionary (what the gate really passes)' {
        function Test-Bound { param([int]$TimeoutMinutes, [switch]$AllowUnreviewed, [switch]$EnableCopilot) Get-GateChildArgs -Repo 'o/a' -Number 1 -Bound $PSBoundParameters }
        $a = Test-Bound -TimeoutMinutes 4 -AllowUnreviewed
        ($a -join ' ') | Should -Match '-TimeoutMinutes 4'
        $a | Should -Contain '-AllowUnreviewed'
        $a | Should -Not -Contain '-EnableCopilot'
    }
    It 'does not forward a switch that was passed as false, nor RecordReview / InstallRuleset' {
        $a = Get-GateChildArgs -Repo 'o/a' -Number 5 -Bound @{ AllowUnreviewed = $false; RecordReview = [switch]$true; InstallRuleset = [switch]$true }
        $a | Should -Not -Contain '-AllowUnreviewed'
        $a | Should -Not -Contain '-RecordReview'
        $a | Should -Not -Contain '-InstallRuleset'
    }
}

Describe 'Get-RecordedPullRequests' {
    It 'lists the PRs recorded for an issue, de-duplicated, and nothing for other issues' {
        $rows = @(
            [pscustomobject]@{ issue = 271; prs = @([pscustomobject]@{ repo = 'o/a'; number = 5 }, [pscustomobject]@{ repo = 'o/b'; number = 9 }) },
            [pscustomobject]@{ issue = 271; prs = @([pscustomobject]@{ repo = 'O/A'; number = 5 }) },
            [pscustomobject]@{ issue = 300; prs = @([pscustomobject]@{ repo = 'o/z'; number = 1 }) })
        Get-RecordedPullRequests -Entries $rows -Issue 271 | Should -Be @('o/a#5', 'o/b#9')
    }
    It 'returns nothing for an issue with no session, or a row without prs' {
        @(Get-RecordedPullRequests -Entries @([pscustomobject]@{ issue = 1 }) -Issue 1).Count | Should -Be 0
        @(Get-RecordedPullRequests -Entries @() -Issue 1).Count | Should -Be 0
    }
}

Describe 'Invoke-GateMulti (children faked at the spawn seam)' {
    It 'passes only when every PR passed, and runs every PR' {
        $r = Invoke-Multi -Codes @{} -Specs @('o/a#5', 'o/b#9')
        $r.Code | Should -Be 0
        $r.Calls.Count | Should -Be 2
        $r.Text | Should -Match 'GATE APROBADO'
    }
    It 'one blocked PR blocks the run - and the others are still judged and reported' {
        $r = Invoke-Multi -Codes @{ 'o/a#5' = 1 } -Specs @('o/a#5', 'o/b#9', 'o/c#2')
        $r.Code | Should -Be 1
        $r.Calls.Count | Should -Be 3
        $r.Text | Should -Match 'o/a#5\s+BLOQUEADO'
        $r.Text | Should -Match 'o/b#9\s+APROBADO'
        $r.Text | Should -Match 'GATE BLOQUEADO'
    }
    It 'a child that could not run (no exit code) is UNKNOWN and the run is not a pass' {
        $r = Invoke-Multi -Codes @{ 'o/b#9' = $null } -Specs @('o/a#5', 'o/b#9')
        $r.Code | Should -Be 4
        $r.Text | Should -Match 'DESCONOCIDO'
        $r.Text | Should -Match 'No es un aprobado'
    }
    It 'passes the exit code 3 (CI never ran) and 2 (unreviewed) through as non-passes' {
        (Invoke-Multi -Codes @{ 'o/a#5' = 3 } -Specs @('o/a#5', 'o/b#9')).Code | Should -Be 3
        (Invoke-Multi -Codes @{ 'o/a#5' = 2 } -Specs @('o/a#5', 'o/b#9')).Code | Should -Be 2
    }
    It 'gates a PR once however many times it is listed' {
        $r = Invoke-Multi -Codes @{} -Specs @('o/a#5', 'O/A#5', 'o/a#5')
        $r.Calls.Count | Should -Be 1
    }
    It 'refuses a spec it does not understand BEFORE spawning anything' {
        $r = Invoke-Multi -Codes @{} -Specs @('o/a#5', 'garbage')
        $r.Code | Should -Be 4
        $r.Calls.Count | Should -Be 0
    }
    It 'takes a bare number only with a default repo' {
        (Invoke-Multi -Codes @{} -Specs @('7') -DefaultRepo 'o/x').Calls[0] | Should -Be @('-Repo', 'o/x', '-PR', '7')
        (Invoke-Multi -Codes @{} -Specs @('7')).Code | Should -Be 4
    }
    It 'refuses an empty selection - nothing to approve is not an approval' {
        $r = Invoke-Multi -Codes @{} -Specs @()
        $r.Code | Should -Be 4
        $r.Text | Should -Match 'No hay ningun PR que revisar'
    }
    It 'forwards the caller''s switches to every child' {
        $r = Invoke-Multi -Codes @{} -Specs @('o/a#5', 'o/b#9') -Bound @{ RequireIndependentReviewer = [switch]$true; CiTimeoutMinutes = 3 }
        foreach ($c in $r.Calls) { $c | Should -Contain '-RequireIndependentReviewer'; ($c -join ' ') | Should -Match '-CiTimeoutMinutes 3' }
    }
}

Describe 'Invoke-GateMulti -Issue reads the PRs recorded for the session (real sessions.json)' {
    BeforeAll {
        $script:State = Join-Path $TestDrive 'state'
        New-Item -ItemType Directory -Path $script:State -Force | Out-Null
        @(
            [pscustomobject]@{ issue = 271; repo = 'home/site'; prs = @([pscustomobject]@{ repo = 'o/a'; number = 5 }, [pscustomobject]@{ repo = 'o/b'; number = 9 }) },
            [pscustomobject]@{ issue = 272; repo = 'home/site'; prs = @() },
            [pscustomobject]@{ issue = 273; repo = 'home/site' }
        ) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $script:State 'sessions.json')
    }
    It 'refuses -Issue together with a list, even when the issue has recorded PRs (no guessing which list wins)' {
        $r = Invoke-Multi -Codes @{} -Specs @('o/z#1') -Issue 271 -StateDir $script:State
        $r.Code | Should -Be 4
        $r.Calls.Count | Should -Be 0
        $r.Text | Should -Match 'no los dos'
    }
    It 'gates every recorded PR of the issue' {
        $r = Invoke-Multi -Codes @{} -Issue 271 -StateDir $script:State
        $r.Code | Should -Be 0
        $r.Calls.Count | Should -Be 2
        $r.Calls[0] | Should -Be @('-Repo', 'o/a', '-PR', '5')
        $r.Calls[1] | Should -Be @('-Repo', 'o/b', '-PR', '9')
    }
    It 'a recorded PR that is blocked blocks the issue''s run' {
        (Invoke-Multi -Codes @{ 'o/b#9' = 1 } -Issue 271 -StateDir $script:State).Code | Should -Be 1
    }
    It 'an issue with no recorded PR, no row, or no registry is unknown - never a pass' {
        foreach ($n in 272, 273, 999) {
            $r = Invoke-Multi -Codes @{} -Issue $n -StateDir $script:State
            $r.Code | Should -Be 4
            $r.Calls.Count | Should -Be 0
        }
        $none = Invoke-Multi -Codes @{} -Issue 271 -StateDir (Join-Path $TestDrive 'nowhere')
        $none.Code | Should -Be 4
        $none.Text | Should -Match 'No hay registro de sesiones'
        (Invoke-Multi -Codes @{} -Issue 272 -StateDir $script:State).Text | Should -Match 'ningun PR anotado'
    }
    It 'an unreadable sessions.json is unknown - never a pass' {
        $bad = Join-Path $TestDrive 'badstate'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bad 'sessions.json') -Value '{ nope'
        $r = Invoke-Multi -Codes @{} -Issue 271 -StateDir $bad
        $r.Code | Should -Be 4
        $r.Calls.Count | Should -Be 0
        $r.Text | Should -Match 'ilegible'
    }
}

Describe 'Board-ReviewGate.ps1 as a real process' {
    BeforeAll {
        function Invoke-Gate {
            param([string[]]$GateArgs)
            $savedTok = $env:GH_TOKEN
            $env:GH_TOKEN = ''
            try {
                $out = pwsh -NoProfile -File $script:Script @GateArgs 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
            } finally { $env:GH_TOKEN = $savedTok }
        }
    }
    It 'a really spawned single-PR gate that fails is a BLOCK for the run, never a pass' {
        # No token is reachable, so the child gate throws and exits 1 - exactly what it does when run
        # by hand. The run must read that as a block.
        $r = Invoke-Gate -GateArgs @('-PullRequests', 'o/r#1', '-TokenVar', 'ABIOS_TEST_TOKEN_THAT_DOES_NOT_EXIST')
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'o/r#1\s+BLOQUEADO'
        $r.Text | Should -Match 'GATE BLOQUEADO'
        $r.Text | Should -Not -Match 'GATE APROBADO'
    }
    It '-Issue with no registry is exit 4 (unknown)' {
        $r = Invoke-Gate -GateArgs @('-Issue', '987654')
        $r.Code | Should -Be 4
        $r.Text | Should -Match 'nada que aprobar'
    }
    It 'refuses to combine the multi-PR form with -RecordReview / -InstallRuleset' {
        (Invoke-Gate -GateArgs @('-PullRequests', 'o/r#1', '-RecordReview')).Code | Should -Be 4
        (Invoke-Gate -GateArgs @('-PullRequests', 'o/r#1', '-InstallRuleset')).Code | Should -Be 4
    }
    It '-PR cannot be mixed with -PullRequests (the parameter sets keep the two forms apart)' {
        $r = Invoke-Gate -GateArgs @('-Repo', 'o/r', '-PR', '5', '-PullRequests', 'o/r#6')
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match '(?i)parameter set|conjunto de par'
    }
    It 'the classic single-PR call still binds and still requires -Repo and -PR exactly as before' {
        $saved = $env:GH_TOKEN; $env:GH_TOKEN = 'fake-token'
        try {
            $noPr = pwsh -NoProfile -File $script:Script -Repo 'o/r' 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally { $env:GH_TOKEN = $saved }
        $code | Should -Be 1
        $noPr | Should -Match 'Usa -PR'
        $noRepo = pwsh -NoProfile -NonInteractive -File $script:Script -PR 5 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
    }
}
