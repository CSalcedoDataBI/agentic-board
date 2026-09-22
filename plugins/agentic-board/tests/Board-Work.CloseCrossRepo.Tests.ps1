#Requires -Modules Pester
<#  Tests for explicit closure of a cross-repo issue (#487, point 5).

    With `Refs` PRs nothing closes the issue on its own. `Board-Work.ps1 -CloseCrossRepo <n>` closes it
    only when EVERY PR recorded for its session is merged, shows the list first, and closes nothing
    without -Force. The cases that matter are the refusals: the first merged PR, an open PR, a PR
    whose state cannot be read, a declared target repo with no PR, no PRs at all. The script tests run
    the REAL Board-Work.ps1 with a fake `gh` first on PATH that logs every call, so "did it close?" is
    read from the calls that were actually made. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''
    function P($repo, $n) { [pscustomobject]@{ repo = $repo; number = $n } }
}

Describe 'Get-IssueClosureVerdict' {
    It 'may close only when at least one PR is recorded and EVERY one is merged' {
        $v = Get-IssueClosureVerdict -Prs @((P 'o/a' 5), (P 'o/b' 9)) -States @{ 'o/a#5' = 'MERGED'; 'o/b#9' = 'MERGED' }
        $v.CanClose | Should -BeTrue
        $v.Merged | Should -Be 2
        $v.Total  | Should -Be 2
    }
    It 'never closes on the first merged PR while another is open' {
        $v = Get-IssueClosureVerdict -Prs @((P 'o/a' 5), (P 'o/b' 9)) -States @{ 'o/a#5' = 'MERGED'; 'o/b#9' = 'OPEN' }
        $v.CanClose | Should -BeFalse
        $v.Reason | Should -Match 'siguen sin mergear: o/b#9'
    }
    It 'a PR closed WITHOUT merging is not merged' {
        (Get-IssueClosureVerdict -Prs @((P 'o/a' 5)) -States @{ 'o/a#5' = 'CLOSED' }).CanClose | Should -BeFalse
    }
    It 'never closes when a PR state is unknown (absent or empty from the read)' {
        $v = Get-IssueClosureVerdict -Prs @((P 'o/a' 5), (P 'o/b' 9)) -States @{ 'o/a#5' = 'MERGED' }
        $v.CanClose | Should -BeFalse
        $v.Reason | Should -Match 'no pude leer el estado de: o/b#9'
        (Get-IssueClosureVerdict -Prs @((P 'o/a' 5)) -States @{ 'o/a#5' = '' }).CanClose | Should -BeFalse
    }
    It 'never closes when no PR is recorded (an empty list is not "all merged")' {
        $v = Get-IssueClosureVerdict -Prs @() -States @{}
        $v.CanClose | Should -BeFalse
        $v.Reason | Should -Match 'ningun PR anotado'
    }
    It 'never closes while a declared target repo has no recorded PR' {
        $v = Get-IssueClosureVerdict -Prs @((P 'o/a' 5)) -States @{ 'o/a#5' = 'MERGED' } -TargetRepos @('o/a', 'o/b')
        $v.CanClose | Should -BeFalse
        $v.Reason | Should -Match 'sin PR anotado: o/b'
    }
    It 'closes when every declared target has a merged PR (case-insensitive repo match)' {
        (Get-IssueClosureVerdict -Prs @((P 'O/A' 5), (P 'o/b' 9)) -States @{ 'O/A#5' = 'MERGED'; 'o/b#9' = 'MERGED' } -TargetRepos @('o/a', 'o/b')).CanClose | Should -BeTrue
    }
}

Describe 'Format-ClosurePlanLines' {
    It 'shows every PR with its state and the verdict' {
        $prs = @((P 'o/a' 5), (P 'o/b' 9))
        $st  = @{ 'o/a#5' = 'MERGED' }
        $v   = Get-IssueClosureVerdict -Prs $prs -States $st
        $t = (Format-ClosurePlanLines -IssueNum 271 -Repo 'home/site' -Prs $prs -States $st -Verdict $v) -join "`n"
        $t | Should -Match 'home/site#271'
        $t | Should -Match 'o/a#5 \[MERGED\]'
        $t | Should -Match 'o/b#9 \[estado desconocido\]'
        $t | Should -Match 'NO se cierra'
    }
}

Describe 'the -CloseCrossRepo mode (real script, fake gh)' {
    BeforeAll {
        $script:Fake = Join-Path $TestDrive 'fakegh'
        New-Item -ItemType Directory -Path $script:Fake -Force | Out-Null
        $ghScript = @'
$a = @($args); $line = $a -join ' '
if ($env:FAKEGH_LOG) { Add-Content -LiteralPath $env:FAKEGH_LOG -Value $line }
if ($line -match '^pr view (\d+) --repo (\S+) --json state') {
    $k = "$($Matches[2])#$($Matches[1])"
    $map = @{}; foreach ($p in ("$env:FAKEGH_STATES" -split ';')) { if ($p -match '^(.+)=(.+)$') { $map[$Matches[1]] = $Matches[2] } }
    if ($map.ContainsKey($k)) { Write-Output ('{"state":"' + $map[$k] + '"}'); exit 0 }
    [Console]::Error.WriteLine('HTTP 404 not found'); exit 1
}
if ($line -match '^issue view \d+ --repo \S+ --json state') {
    $s = if ($env:FAKEGH_ISSUE) { $env:FAKEGH_ISSUE } else { 'OPEN' }
    Write-Output ('{"state":"' + $s + '"}'); exit 0
}
if ($line -match '^issue close ') { exit 0 }
[Console]::Error.WriteLine("fakegh: unexpected call: $line"); exit 1
'@
        Set-Content -LiteralPath (Join-Path $script:Fake 'gh.ps1') -Value $ghScript

        function New-SessionRepo {
            param([string]$Name, [string[]]$Targets, [object[]]$Prs)
            $p = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Push-Location $p
            try {
                git init -q -b main 2>&1 | Out-Null
                Write-SessionRegistryEntry -IssueNum 271 -Branch 'issue-271-x' -WorkPath 'C:/w' -Repo 'home/site' -SessionPid 4242 -Via 'pwsh' `
                                           -TargetRepos $Targets -CrossRepo $true
                foreach ($pr in $Prs) { Add-SessionPullRequest -IssueNum 271 -Repo $pr.repo -Number $pr.number | Out-Null }
            } finally { Pop-Location }
            $p
        }
        function Invoke-Close {
            param([string]$RepoDir, [string]$States, [string[]]$Extra = @(), [string]$IssueState = 'OPEN', [int]$Issue = 271)
            $log = Join-Path $TestDrive ("calls-" + [guid]::NewGuid().ToString('N') + ".log")
            $sp = $env:PATH; $st = $env:GH_TOKEN
            $env:PATH = "$($script:Fake)$([IO.Path]::PathSeparator)$sp"
            $env:GH_TOKEN = 'fake-token'; $env:FAKEGH_LOG = $log; $env:FAKEGH_STATES = $States; $env:FAKEGH_ISSUE = $IssueState
            try {
                Push-Location $RepoDir
                $out = pwsh -NoProfile -File $script:Script -CloseCrossRepo $Issue @Extra 2>&1 | Out-String
                $code = $LASTEXITCODE
                Pop-Location
            } finally {
                $env:PATH = $sp; $env:GH_TOKEN = $st
                Remove-Item Env:FAKEGH_LOG, Env:FAKEGH_STATES, Env:FAKEGH_ISSUE -ErrorAction SilentlyContinue
            }
            $calls = if (Test-Path $log) { @(Get-Content $log) } else { @() }
            [pscustomobject]@{ Code = $code; Text = $out; Closed = @($calls | Where-Object { $_ -match '^issue close ' }).Count; Calls = $calls }
        }
        $script:Two = @((P 'o/a' 5), (P 'o/b' 9))
    }

    It 'shows the list and closes NOTHING without -Force, even when every PR is merged' {
        $d = New-SessionRepo 'c1' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=MERGED'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'o/a#5 \[MERGED\]'
        $r.Text | Should -Match 'o/b#9 \[MERGED\]'
        $r.Text | Should -Match 'No cerre nada'
        $r.Closed | Should -Be 0
    }
    It 'closes the issue with -Force when EVERY recorded PR is merged, and says which PRs' {
        $d = New-SessionRepo 'c2' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=MERGED' -Extra @('-Force')
        $r.Code | Should -Be 0
        $r.Closed | Should -Be 1
        (@($r.Calls | Where-Object { $_ -match '^issue close 271 --repo home/site --reason completed' }).Count) | Should -Be 1
        $r.Text | Should -Match 'cerrado'
    }
    It 'never closes on the first merged PR while another is still open, even with -Force' {
        $d = New-SessionRepo 'c3' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=OPEN' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'siguen sin mergear: o/b#9'
    }
    It 'never closes when a PR state cannot be read, even with -Force' {
        $d = New-SessionRepo 'c4' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'no pude leer el estado'
    }
    It 'never closes a PR closed without merging' {
        $d = New-SessionRepo 'c5' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=CLOSED' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
    }
    It 'never closes while a declared target repo has no recorded PR, even with -Force' {
        $d = New-SessionRepo 'c6' @('o/a', 'o/b', 'o/c') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=MERGED' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'sin PR anotado: o/c'
    }
    It 'never closes an issue with no recorded PR' {
        $d = New-SessionRepo 'c7' @('o/a') @()
        $r = Invoke-Close -RepoDir $d -States '' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
    }
    It 'never closes an issue that has no session' {
        $d = Join-Path $TestDrive 'c8'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Push-Location $d; git init -q -b main 2>&1 | Out-Null; Pop-Location
        $r = Invoke-Close -RepoDir $d -States '' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'no hay registro de sesiones|no tiene sesion registrada'
    }
    It 'says a session is missing (not that a repo is missing) when the registry has other issues only' {
        $d = New-SessionRepo 'c8b' @('o/a') @()
        $r = Invoke-Close -RepoDir $d -States '' -Extra @('-Force') -Issue 999
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'no tiene sesion registrada'
    }
    It 'never closes when sessions.json is unreadable, and says so' {
        $d = New-SessionRepo 'c8c' @('o/a') @()
        Push-Location $d
        try { $p = Get-SessionRegistryPath; Set-Content -LiteralPath $p -Value '{ nope' } finally { Pop-Location }
        $r = Invoke-Close -RepoDir $d -States '' -Extra @('-Force')
        $r.Code | Should -Be 1
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'ilegible'
    }
    It 'leaves an issue that is already closed alone' {
        $d = New-SessionRepo 'c9' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=MERGED' -Extra @('-Force') -IssueState 'CLOSED'
        $r.Code | Should -Be 0
        $r.Closed | Should -Be 0
        $r.Text | Should -Match 'ya esta'
    }
    It '-DryRun with -Force still closes nothing' {
        $d = New-SessionRepo 'c10' @('o/a', 'o/b') $script:Two
        $r = Invoke-Close -RepoDir $d -States 'o/a#5=MERGED;o/b#9=MERGED' -Extra @('-Force', '-DryRun')
        $r.Closed | Should -Be 0
    }
}

Describe 'Show-SessionFleet reports whether the issue may be closed' {
    It 'says LISTO PARA CERRAR only when every recorded PR is merged' {
        $script:Rows = @([pscustomobject]@{ issue = 271; repo = 'home/site'; branch = 'issue-271-x'; workPath = 'C:/w'; sessionPid = 1; via = 'pwsh'; cli = 'claude'
                                            host = 'h'; started = 's'; crossRepo = $true; targetRepos = @('o/a', 'o/b')
                                            prs = @((P 'o/a' 5), (P 'o/b' 9)) })
        Mock Read-SessionRegistry { $script:Rows }
        Mock Get-SessionMetrics { [pscustomobject]@{ Alive = $true; RamMB = 1; CpuSec = 1 } }
        Mock Get-LogTailLines { @() }
        Mock Get-SessionPrStates { @{ 'o/a#5' = 'MERGED'; 'o/b#9' = 'OPEN' } }
        $one = & { Show-SessionFleet } 6>&1 | Out-String
        $one | Should -Match 'Todavia no se cierra: siguen sin mergear: o/b#9'
        $one | Should -Not -Match 'LISTO PARA CERRAR'
        Mock Get-SessionPrStates { @{ 'o/a#5' = 'MERGED'; 'o/b#9' = 'MERGED' } }
        $two = & { Show-SessionFleet } 6>&1 | Out-String
        $two | Should -Match 'LISTO PARA CERRAR'
    }
}
