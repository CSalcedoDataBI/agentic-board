#Requires -Modules Pester
<#  Tests for scripts/Get-ActionsCostAudit.ps1 - the read-only Actions cost audit (#614).

    What is under test is the REAL code: the YAML-subset parser, every rule, the usage
    aggregation and the whole engine. The only thing mocked is Invoke-GhRaw, the one place the gh
    executable is touched (Invoke-Gh.ps1), so the fail-closed wrapper, the endpoint routing and the
    parsing of gh's answers all run for real - no token, no network.

    The shape of the guarantees, because they are the point of the feature:
      - a finding always carries a file and a line, and the line it quotes is the line in the file;
      - anything the audit cannot measure lands in Unmeasured with a reason, never as a clean pass
        and never as a zero (an unreadable usage endpoint must NOT print 0 minutes);
      - the audit writes nothing: every gh call is a plain GET. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-ActionsCostAudit.ps1' | Resolve-Path
    $env:ABIOS_ACTIONSCOST_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_ACTIONSCOST_DOTSOURCE = ''

    # Run the per-file rules over inline workflow files: @{ 'ci.yml' = '<yaml>' }.
    function script:Invoke-Rules {
        param([hashtable]$Yaml, $Required = $null, [string]$Default = 'main')
        $models = @($Yaml.Keys | Sort-Object | ForEach-Object { ConvertTo-WorkflowModel $_ $Yaml[$_] })
        $ctx = New-AuditContext
        if (-not $Required) { $Required = [pscustomobject]@{ Contexts = @(); Complete = $true; Reason = '' } }
        $pe = Invoke-WorkflowRules $ctx $models $Default $Required
        [pscustomobject]@{ Findings = @($ctx.Findings); Unmeasured = @($ctx.Unmeasured); Ledger = $ctx.Ledger; PerEvent = @($pe); Models = $models }
    }
    function script:Only { param($R, [string]$Rule) @($R.Findings | Where-Object { $_.Rule -eq $Rule }) }
    function script:Unm { param($R, [string]$Rule) @($R.Unmeasured | Where-Object { $_.Rule -eq $Rule }) }

    # A minimal well-behaved job, so a fixture only states the thing it is about.
    $script:Ok = "  build:`n    runs-on: ubuntu-latest`n    timeout-minutes: 10`n    steps:`n      - run: echo hi`n"
}

Describe 'YAML subset parser' {
    It 'reads nested mappings, sequences, compact sequence items and keeps line numbers' {
        $y = @'
name: CI
on:
  pull_request:
    branches: [main, 'release/*']
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: npm ci
'@
        $root = ConvertFrom-WorkflowYaml $y
        (Get-YText (Get-YChild $root 'name')) | Should -Be 'CI'
        $on = Get-YChild $root 'on'
        $on.KeyLine['pull_request'] | Should -Be 3
        (Get-YStrings (Get-YChild (Get-YChild $on 'pull_request') 'branches')) | Should -Be @('main', 'release/*')
        $steps = (Get-YChild (Get-YChild (Get-YChild $root 'jobs') 'test') 'steps').Items
        $steps.Count | Should -Be 2
        $steps[0].Line | Should -Be 9
        (Get-YText (Get-YChild $steps[1] 'run')) | Should -Be 'npm ci'
        $steps[1].KeyLine['run'] | Should -Be 11
    }

    It 'cuts comments but keeps a # inside quotes and inside a URL' {
        $y = "a: 1  # note`nb: 'x # y'`nc: `"p # q`"`nd: http://h/#frag`n"
        $root = ConvertFrom-WorkflowYaml $y
        (Get-YText (Get-YChild $root 'a')) | Should -Be '1'
        (Get-YText (Get-YChild $root 'b')) | Should -Be 'x # y'
        (Get-YText (Get-YChild $root 'c')) | Should -Be 'p # q'
        (Get-YText (Get-YChild $root 'd')) | Should -Be 'http://h/#frag'
    }

    It 'treats " #" inside a PLAIN scalar as a comment, exactly as YAML does' {
        $root = ConvertFrom-WorkflowYaml "run: echo `"a #b`"`n"
        (Get-YText (Get-YChild $root 'run')) | Should -Be 'echo "a'
    }

    It 'keeps a block scalar whole, including lines that look like keys and comments' {
        $y = @'
steps:
  - run: |
      npm ci
      # not a comment: it is script text
      key: value
  - run: echo next
'@
        $root = ConvertFrom-WorkflowYaml $y
        $steps = (Get-YChild $root 'steps').Items
        (Get-YText (Get-YChild $steps[0] 'run')) | Should -Be "npm ci`n# not a comment: it is script text`nkey: value"
        (Get-YText (Get-YChild $steps[1] 'run')) | Should -Be 'echo next'
    }

    It 'folds a > block scalar into one line (a shell sees ONE command) and keeps a | block as lines' {
        $root = ConvertFrom-WorkflowYaml "a: >`n  echo preparing`n  npm ci`n`n  next`nb: |`n  echo preparing`n  npm ci`n"
        (Get-YText (Get-YChild $root 'a')) | Should -Be "echo preparing npm ci`nnext"
        (Get-YText (Get-YChild $root 'b')) | Should -Be "echo preparing`nnpm ci"
    }
    It 'reads flow sequences and mappings, including one that spans lines' {
        $y = "a: [x, y,`n    z]`nb: { k: v, n: [1, 2] }`nc: []`n"
        $root = ConvertFrom-WorkflowYaml $y
        (Get-YStrings (Get-YChild $root 'a')) | Should -Be @('x', 'y', 'z')
        (Get-YText (Get-YChild (Get-YChild $root 'b') 'k')) | Should -Be 'v'
        (Get-YChild $root 'c').Items.Count | Should -Be 0
    }

    It 'accepts a sequence at the same column as its key and a plain scalar that continues on the next line' {
        $y = "on:`n  push:`n    branches:`n    - main`n    - dev`nrun: echo a`n  b`n"
        $root = ConvertFrom-WorkflowYaml $y
        (Get-YStrings (Get-YChild (Get-YChild (Get-YChild $root 'on') 'push') 'branches')) | Should -Be @('main', 'dev')
        (Get-YText (Get-YChild $root 'run')) | Should -Be 'echo a b'
    }

    It 'a key with no value is null, not an error (workflow_dispatch:)' {
        $root = ConvertFrom-WorkflowYaml "on:`n  workflow_dispatch:`n  push:`n    branches: [main]`n"
        (Get-YChild (Get-YChild $root 'on') 'workflow_dispatch').Kind | Should -Be 'null'
    }

    It '<Why> makes the file NOT parsed, with a reason - never a half-audit' -ForEach @(
        @{ Why = 'an anchor';            Yaml = "a: &x 1`nb: 2`n" }
        @{ Why = 'an alias';             Yaml = "a: 1`nb: *x`n" }
        @{ Why = 'a tab in indentation'; Yaml = "a:`n`tb: 1`n" }
        @{ Why = 'a second document';    Yaml = "a: 1`n---`nb: 2`n" }
        @{ Why = 'a duplicate key';      Yaml = "a: 1`na: 2`n" }
        @{ Why = 'an unterminated flow'; Yaml = "a: [x, y`nb: 1`n" }
        @{ Why = 'a quote that runs onto the next line'; Yaml = "a: `"abc`n  def`"`n" }
    ) {
        $m = ConvertTo-WorkflowModel 'x.yml' $Yaml
        $m.Parsed | Should -BeFalse
        $m.Error | Should -Not -BeNullOrEmpty
    }

    It 'a file the parser rejects is reported as not measured, and none of its rules run' {
        $r = Invoke-Rules @{ 'bad.yml' = "on: push`njobs:`n  a: &anchor`n    runs-on: ubuntu-latest`n" }
        $r.Findings.Count | Should -Be 0
        (Unm $r 'PARSE').Count | Should -Be 1
        (Unm $r 'PARSE')[0].File | Should -Be 'bad.yml'
    }

    It 'parses every workflow this repository actually ships (the real-world smoke test)' {
        $dir = Join-Path $PSScriptRoot '..' '..' '..' '.github' 'workflows'
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.yml')
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            $m = ConvertTo-WorkflowModel $f.Name ([IO.File]::ReadAllText($f.FullName))
            $m.Parsed | Should -BeTrue -Because "$($f.Name): $($m.Error)"
            @($m.Jobs).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Cron frequency' {
    It "'<Expr>' -> <PerWeek> run(s) a week, flagged as more than weekly: <Frequent>" -ForEach @(
        @{ Expr = '0 9 * * 1';     PerWeek = 1;   Frequent = $false }   # weekly
        @{ Expr = '0 9 1 * *';     PerWeek = 0.23; Frequent = $false }  # monthly
        @{ Expr = '0 9 * * *';     PerWeek = 7;   Frequent = $true }    # daily
        @{ Expr = '0 9 * * 1-5';   PerWeek = 5;   Frequent = $true }    # weekdays
        @{ Expr = '0 */6 * * *';   PerWeek = 28;  Frequent = $true }    # every 6 hours
        @{ Expr = '*/15 * * * *';  PerWeek = 672; Frequent = $true }    # every 15 minutes
        @{ Expr = '0 9 * * MON';   PerWeek = 1;   Frequent = $false }   # weekly, named
        @{ Expr = '0 9,21 * * 1';  PerWeek = 2;   Frequent = $true }    # weekly but twice a day
        @{ Expr = '0 0 */2 * *';   PerWeek = 3.61; Frequent = $true }   # every other day of the month
        @{ Expr = '0 9 * 1 *';     PerWeek = 0.58; Frequent = $false }  # daily, but only in January: 31 runs a year, fewer than weekly
        @{ Expr = '0 9 * 1-6 *';   PerWeek = 3.5;  Frequent = $true }   # daily for half the year
    ) {
        $f = Get-CronFrequency $Expr
        $f.Parsed | Should -BeTrue
        $f.PerWeek | Should -Be $PerWeek
        ($f.PerWeek -gt 1) | Should -Be $Frequent
    }

    It "'<Expr>' is not a cron this audit can read, and says so" -ForEach @(
        @{ Expr = '@daily' }
        @{ Expr = '0 9 * *' }
        @{ Expr = '61 9 * * *' }
        @{ Expr = '0 9 * * FUNDAY' }
        @{ Expr = '0 25 * * *' }
    ) {
        $f = Get-CronFrequency $Expr
        $f.Parsed | Should -BeFalse
        $f.Reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'R1 - the same job on pull_request and push' {
    It 'flags every job of a workflow gated on both pull_request and push: main (medium)' {
        $y = "on:`n  pull_request:`n    branches: [main]`n  push:`n    branches: [main]`njobs:`n$script:Ok  lint:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        $f = Only $r 'R1'
        $f.Count | Should -Be 2
        $f[0].Severity | Should -Be 'medium'
        $f[0].File | Should -Be 'ci.yml'
        ($f | ForEach-Object { $_.Message }) -join ' ' | Should -Match "job 'build'"
        ($f | ForEach-Object { $_.Message }) -join ' ' | Should -Match "job 'lint'"
    }

    It 'a push with no branch filter is HIGH: a commit on a PR branch is judged twice' {
        $r = Invoke-Rules @{ 'ci.yml' = "on: [push, pull_request]`njobs:`n$script:Ok" }
        $f = Only $r 'R1'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'high'
        $f[0].Message | Should -Match 'cada push a cualquier rama'
    }

    It 'a job whose if: separates the events is not flagged' {
        $y = "on:`n  pull_request:`n  push:`n    branches: [main]`njobs:`n  deploy:`n    if: github.event_name == 'push'`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R1').Count | Should -Be 0
    }

    It 'a tags-only push is not a second run of the PR gate' {
        (Only (Invoke-Rules @{ 'a.yml' = "on:`n  pull_request:`n  push:`n    tags: ['v*']`njobs:`n$script:Ok" }) 'R1').Count | Should -Be 0
    }

    It 'a push to ANOTHER branch can still double-run a PR opened from it: low for a literal name, medium for a wildcard' {
        # pull_request.branches filters the PR BASE, push.branches the pushed branch - different questions
        $lit = Only (Invoke-Rules @{ 'b.yml' = "on:`n  pull_request:`n    branches: [main]`n  push:`n    branches: [develop]`njobs:`n$script:Ok" }) 'R1'
        $lit.Count | Should -Be 1
        $lit[0].Severity | Should -Be 'low'
        $lit[0].Message | Should -Match 'develop'
        $wild = Only (Invoke-Rules @{ 'c.yml' = "on:`n  pull_request:`n    branches: [main]`n  push:`n    branches: ['feature/**']`njobs:`n$script:Ok" }) 'R1'
        $wild.Count | Should -Be 1
        $wild[0].Severity | Should -Be 'medium'
        $wild[0].Message | Should -Match 'feature/\*\*'
    }

    It 'a push to main AND to a wildcard branch reports both overlaps in ONE finding per job' {
        $f = Only (Invoke-Rules @{ 'd.yml' = "on:`n  pull_request:`n  push:`n    branches: [main, 'feature/**']`njobs:`n$script:Ok" }) 'R1'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match 'push a main'
        $f[0].Message | Should -Match 'feature/\*\*'
    }

    It 'a push that only IGNORES branches still runs on every other branch: HIGH, and it names what it skips' {
        $y = "on:`n  pull_request:`n  push:`n    branches-ignore: [main]`njobs:`n$script:Ok"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R1'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'high'
        $f[0].Message | Should -Match 'salvo main'
    }

    It 'a push that fires only on a branch the PR gate does not target and cannot be a PR head is quiet' {
        $y = "on:`n  pull_request:`n    branches: [develop]`n  push:`n    branches: [main]`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R1').Count | Should -Be 0
    }
    It 'a pull_request that only targets another base branch does not overlap a push to main' {
        $y = "on:`n  pull_request:`n    branches: [develop]`n  push:`n    branches: [main]`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R1').Count | Should -Be 0
    }

    It 'a branch pattern it cannot evaluate is NOT MEASURED, not a pass' {
        $y = "on:`n  pull_request:`n  push:`n    branches: ['!wip/**', main]`njobs:`n$script:Ok"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        (Only $r 'R1').Count | Should -Be 0
        (Unm $r 'R1').Count | Should -Be 1
    }

    It 'globs: main matches main and ** and release/*, not feature/x' {
        Test-GlobMatch 'main' 'main' | Should -BeTrue
        Test-GlobMatch '**' 'main' | Should -BeTrue
        Test-GlobMatch 'ma*' 'main' | Should -BeTrue
        Test-GlobMatch 'feature/*' 'main' | Should -BeFalse
        Test-GlobMatch 'release/*' 'release/1.0' | Should -BeTrue
        Test-GlobMatch 'release/*' 'release/1/0' | Should -BeFalse
    }
}

Describe 'R2 - concurrency and cancel-in-progress' {
    It 'no concurrency on a PR workflow is a finding' {
        $r = Invoke-Rules @{ 'ci.yml' = "on: pull_request`njobs:`n$script:Ok" }
        $f = Only $r 'R2'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'medium'
    }

    It 'concurrency with cancel-in-progress: true is clean' {
        $y = "on: pull_request`nconcurrency:`n  group: ci-`${{ github.ref }}`n  cancel-in-progress: true`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R2').Count | Should -Be 0
    }

    It 'concurrency that does not cancel (false or absent) still bills the stale run' {
        $a = "on: pull_request`nconcurrency:`n  group: g`n  cancel-in-progress: false`njobs:`n$script:Ok"
        $b = "on: pull_request`nconcurrency:`n  group: g`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'a.yml' = $a }) 'R2').Count | Should -Be 1
        (Only (Invoke-Rules @{ 'b.yml' = $b }) 'R2').Count | Should -Be 1
    }

    It 'a release workflow must be false: true is HIGH, missing is low, false is clean' {
        $t = "on:`n  push:`n    branches: [main]`nconcurrency:`n  group: release`n  cancel-in-progress: true`njobs:`n$script:Ok"
        $n = "on:`n  push:`n    branches: [main]`njobs:`n$script:Ok"
        $f = "on:`n  push:`n    branches: [main]`nconcurrency:`n  group: release`n  cancel-in-progress: false`njobs:`n$script:Ok"
        $rt = Only (Invoke-Rules @{ 'release.yml' = $t }) 'R2'
        $rt.Count | Should -Be 1; $rt[0].Severity | Should -Be 'high'
        $rn = Only (Invoke-Rules @{ 'release.yml' = $n }) 'R2'
        $rn.Count | Should -Be 1; $rn[0].Severity | Should -Be 'low'
        (Only (Invoke-Rules @{ 'release.yml' = $f }) 'R2').Count | Should -Be 0
    }

    It 'a workflow named Deploy is classified as release even when the file is not' {
        $t = "name: Deploy site`non:`n  push:`n    branches: [main]`nconcurrency:`n  group: d`n  cancel-in-progress: true`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'site.yml' = $t }) 'R2')[0].Severity | Should -Be 'high'
    }

    It 'cancel-in-progress as an expression is not measured' {
        $y = "on: pull_request`nconcurrency:`n  group: g`n  cancel-in-progress: `${{ github.event_name == 'pull_request' }}`njobs:`n$script:Ok"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        (Only $r 'R2').Count | Should -Be 0
        (Unm $r 'R2').Count | Should -Be 1
    }

    It 'a workflow whose every job carries its own concurrency counts as covered' {
        $y = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    concurrency:`n      group: a`n      cancel-in-progress: true`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R2').Count | Should -Be 0
    }

    It 'job-level concurrency is judged per job: a job that cancels does not hide one that does not' {
        $y = "on: pull_request`njobs:`n  fast:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    concurrency:`n      group: f`n      cancel-in-progress: true`n    steps:`n      - run: x`n  slow:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    concurrency:`n      group: s`n      cancel-in-progress: false`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R2'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match "job 'slow'"
        $f[0].Line | Should -Be 14
    }

    It 'some jobs with concurrency and some without: the uncovered jobs are named' {
        $y = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    concurrency:`n      group: a`n      cancel-in-progress: true`n    steps:`n      - run: x`n  b:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R2'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match 'jobs sin concurrency: b'
    }

    It 'a release job with its own cancel-in-progress: true is HIGH even when the workflow has no concurrency' {
        $y = "name: Release`non:`n  push:`n    branches: [main]`njobs:`n  rel:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    concurrency:`n      group: r`n      cancel-in-progress: true`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'release.yml' = $y }) 'R2'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'high'
    }

    It 'a schedule-only workflow is not a per-push cost and is not evaluated by R2' {
        $r = Invoke-Rules @{ 'cron.yml' = "on:`n  schedule:`n    - cron: '0 9 * * 1'`njobs:`n$script:Ok" }
        (Only $r 'R2').Count | Should -Be 0
        $r.Ledger['R2'] | Should -BeNullOrEmpty
    }
}

Describe 'R3 - timeout-minutes on every job' {
    It 'counts the jobs IN THE FILE: two of four without a timeout is exactly two findings' {
        $y = @'
on: pull_request
concurrency: { group: g, cancel-in-progress: true }
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: x
  b:
    runs-on: ubuntu-latest
    steps:
      - run: x
  c:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - run: x
  d:
    runs-on: ubuntu-latest
    steps:
      - run: x
'@
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        $f = Only $r 'R3'
        $f.Count | Should -Be 2
        ($f | ForEach-Object { $_.Line }) | Should -Be @(9, 18)
        $f[0].Severity | Should -Be 'high'
        $r.Ledger['R3'].Evaluated | Should -Be 4
    }

    It 'a reusable-workflow call takes no timeout of its own and is skipped, not flagged' {
        $y = "on: pull_request`njobs:`n  call:`n    uses: ./.github/workflows/x.yml`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        (Only $r 'R3').Count | Should -Be 0
        $r.Ledger.ContainsKey('R3') | Should -BeFalse
    }

    It 'timeout-minutes equal to the default (360) limits nothing, and an expression is not measured' {
        $a = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 360`n    steps:`n      - run: x`n"
        $b = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: `${{ inputs.t }}`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'a.yml' = $a }) 'R3').Count | Should -Be 1
        $rb = Invoke-Rules @{ 'b.yml' = $b }
        (Only $rb 'R3').Count | Should -Be 0
        (Unm $rb 'R3').Count | Should -Be 1
    }
}

Describe 'R4 and the deadlock trap - path filters against required checks' {
    BeforeAll { $script:Req = [pscustomobject]@{ Contexts = @('Pester'); Complete = $true; Reason = '' } }

    It 'no path filter on a required workflow: an advice that says NOT to add one' {
        $y = "on: pull_request`njobs:`n  test:`n    name: Pester`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y } $script:Req) 'R4'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'advice'
        $f[0].Message | Should -Match 'REQUERIDO'
        $f[0].Message | Should -Match "No lo anadas"
        $f[0].Message | Should -Match 'ES el producto'
    }

    It 'no path filter on a workflow that is not required: says a filter cannot deadlock' {
        $f = Only (Invoke-Rules @{ 'lint.yml' = "on: pull_request`njobs:`n$script:Ok" } $script:Req) 'R4'
        $f[0].Message | Should -Match 'no puede dejar una PR en deadlock'
    }

    It 'required checks that could not be read: the advice says verify first, it does not claim safety' {
        $unread = [pscustomobject]@{ Contexts = @(); Complete = $false; Reason = 'HTTP 403' }
        $f = Only (Invoke-Rules @{ 'lint.yml' = "on: pull_request`njobs:`n$script:Ok" } $unread) 'R4'
        $f[0].Message | Should -Match 'comprueba'
        $f[0].Message | Should -Not -Match 'no puede dejar una PR en deadlock'
    }

    It 'a path-filtered workflow whose job IS a required check is the deadlock trap (HIGH)' {
        $y = "on:`n  pull_request:`n    paths-ignore: ['**.md']`njobs:`n  test:`n    name: Pester`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y } $script:Req) 'TRAP'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'high'
        $f[0].Message | Should -Match 'Expected - waiting for status'
        $f[0].Line | Should -Be 2
    }

    It 'a path-filtered workflow that is not required is fine; with unreadable checks it is not measured' {
        $y = "on:`n  pull_request:`n    paths: ['src/**']`njobs:`n$script:Ok"
        (Only (Invoke-Rules @{ 'ci.yml' = $y } $script:Req) 'TRAP').Count | Should -Be 0
        $unread = [pscustomobject]@{ Contexts = @(); Complete = $false; Reason = 'HTTP 403' }
        $r = Invoke-Rules @{ 'ci.yml' = $y } $unread
        (Only $r 'TRAP').Count | Should -Be 0
        (Unm $r 'TRAP').Count | Should -Be 1
    }

    It 'a pull_request_target workflow is judged like a pull_request one: the path-filter trap and the advice both apply' {
        $y = "on:`n  pull_request_target:`n    paths: ['src/**']`njobs:`n  test:`n    name: Pester`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y } $script:Req) 'TRAP'
        $f.Count | Should -Be 1
        $f[0].Line | Should -Be 2
        $n = "on: pull_request_target`njobs:`n  test:`n    name: Pester`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $adv = Only (Invoke-Rules @{ 'ci.yml' = $n } $script:Req) 'R4'
        $adv.Count | Should -Be 1
        $adv[0].Message | Should -Match '^pull_request_target sin paths'
        $adv[0].Message | Should -Match 'REQUERIDO'
    }

    It 'a matrix job named with an expression is matched by its literal prefix; a name that STARTS with one is not measured' {
        $j = [pscustomobject]@{ Id = 'test'; Name = 'Test ${{ matrix.os }}'; Uses = $null }
        Test-CheckMatchesJob 'Test ubuntu-latest' $j | Should -BeTrue
        Test-CheckMatchesJob 'Lint ubuntu-latest' $j | Should -BeFalse
        $y = "on:`n  pull_request:`n    paths: ['src/**']`njobs:`n  a:`n    name: `${{ matrix.os }} build`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y } $script:Req
        (Only $r 'TRAP').Count | Should -Be 0
        (Unm $r 'TRAP').Count | Should -Be 1
        (Unm $r 'TRAP')[0].Reason | Should -Match 'expresion'
        $n = "on: pull_request`njobs:`n  a:`n    name: `${{ matrix.os }} build`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $n } $script:Req) 'R4')[0].Message | Should -Match 'empieza por una expresion'
    }

    It 'a match that rests only on the literal prefix of an expression name is MEDIUM and says so; an exact match stays HIGH' {
        $req = [pscustomobject]@{ Contexts = @('Test ubuntu-latest'); Complete = $true; Reason = '' }
        $y = "on:`n  pull_request:`n    paths: ['src/**']`njobs:`n  a:`n    name: Test `${{ matrix.os }}`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y } $req) 'TRAP'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'medium'
        $f[0].Message | Should -Match 'prefijo'
        $j = [pscustomobject]@{ Id = 'a'; Name = 'Test ${{ matrix.os }}'; Uses = $null }
        Get-CheckMatchKind 'Test ubuntu-latest' $j | Should -Be 'prefix'
        Get-CheckMatchKind 'a' $j | Should -Be 'exact'
        Get-CheckMatchKind 'Lint' $j | Should -Be ''
        # the ordinary case is unchanged: an exact name is HIGH
        $exact = "on:`n  pull_request:`n    paths: ['src/**']`njobs:`n  a:`n    name: Pester`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $exact } $script:Req) 'TRAP')[0].Severity | Should -Be 'high'
    }
    It 'matches a required context to a job by name, by id, and to a matrix job by prefix' {
        $j = [pscustomobject]@{ Id = 'test'; Name = 'Pester' }
        Test-CheckMatchesJob 'Pester' $j | Should -BeTrue
        Test-CheckMatchesJob 'test' $j | Should -BeTrue
        Test-CheckMatchesJob 'Pester (ubuntu, 20)' $j | Should -BeTrue
        Test-CheckMatchesJob 'Pesterx' $j | Should -BeFalse
        Test-CheckMatchesJob 'build' $j | Should -BeFalse
    }
}

Describe 'Required checks of a job that calls a reusable workflow' {
    It 'matches the caller-job / called-job form for a calling job only' {
        $call = [pscustomobject]@{ Id = 'ci'; Name = $null; Uses = './.github/workflows/build.yml' }
        Test-CheckMatchesJob 'ci / build' $call | Should -BeTrue
        $plain = [pscustomobject]@{ Id = 'ci'; Name = $null; Uses = $null }
        Test-CheckMatchesJob 'ci / build' $plain | Should -BeFalse
    }
}
Describe 'R5 - windows and macos runners on a branch push' {
    It 'windows on a push to a branch is a finding that names the x2 multiplier' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: windows-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R5'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match 'x2'
        $f[0].Line | Should -Be 6
    }

    It 'macos is x10; a tags-only push and a pull_request-only workflow are not branch pushes' {
        $m = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: macos-14`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'a.yml' = $m }) 'R5')[0].Message | Should -Match 'x10'
        $t = "on:`n  push:`n    tags: ['v*']`njobs:`n  a:`n    runs-on: windows-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'b.yml' = $t }) 'R5').Count | Should -Be 0
        $p = "on: pull_request`njobs:`n  a:`n    runs-on: windows-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'c.yml' = $p }) 'R5').Count | Should -Be 0
    }

    It 'resolves runs-on: ${{ matrix.os }} from the matrix and flags only the windows entry' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: `${{ matrix.os }}`n    timeout-minutes: 5`n    strategy:`n      matrix:`n        os: [ubuntu-latest, windows-latest]`n    steps:`n      - run: x`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R5'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match 'windows-latest'
    }

    It 'a matrix with exclude is NOT resolved: the excluded runner never starts, so it must not be flagged' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: `${{ matrix.os }}`n    timeout-minutes: 5`n    strategy:`n      matrix:`n        os: [ubuntu-latest, macos-latest]`n        exclude:`n          - os: macos-latest`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        (Only $r 'R5').Count | Should -Be 0
        (Unm $r 'R5').Count | Should -Be 1
        (Unm $r 'R5')[0].Reason | Should -Match 'exclude'
    }
    It 'a self-hosted runner spends no GitHub-hosted minutes, whatever its os label says' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: [self-hosted, windows, x64]`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'R5').Count | Should -Be 0
    }
    It 'a runs-on expression it cannot resolve is not measured' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: `${{ inputs.runner }}`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        (Only $r 'R5').Count | Should -Be 0
        (Unm $r 'R5').Count | Should -Be 1
    }
}

Describe 'R6 - retention-days and caches' {
    It 'upload-artifact without retention-days is flagged; with it, clean' {
        $bad  = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - uses: actions/upload-artifact@v4`n        with:`n          name: r`n"
        $good = "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - uses: actions/upload-artifact@v4`n        with:`n          name: r`n          retention-days: 7`n"
        $f = Only (Invoke-Rules @{ 'a.yml' = $bad }) 'R6'
        $f.Count | Should -Be 1
        $f[0].Line | Should -Be 7
        (Only (Invoke-Rules @{ 'b.yml' = $good }) 'R6').Count | Should -Be 0
    }

    It 'setup-node without cache: is flagged; with cache:, or with an actions/cache step, it is not' {
        $mk = { param($steps) "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n$steps" }
        $none = & $mk "      - uses: actions/setup-node@v4`n        with:`n          node-version: 20`n"
        $with = & $mk "      - uses: actions/setup-node@v4`n        with:`n          node-version: 20`n          cache: npm`n"
        $manual = & $mk "      - uses: actions/cache@v4`n        with:`n          path: x`n          key: k`n      - uses: actions/setup-node@v4`n"
        (Only (Invoke-Rules @{ 'a.yml' = $none }) 'R6').Count | Should -Be 1
        (Only (Invoke-Rules @{ 'b.yml' = $with }) 'R6').Count | Should -Be 0
        (Only (Invoke-Rules @{ 'c.yml' = $manual }) 'R6').Count | Should -Be 0
    }

    It 'setup-go caches by default from v4: v5 is clean, v3 and cache: false are flagged, a sha pin is not measured' {
        $mk = { param($uses, $extra) "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - uses: $uses`n$extra" }
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'actions/setup-go@v5' '') }) 'R6').Count | Should -Be 0
        (Only (Invoke-Rules @{ 'b.yml' = (& $mk 'actions/setup-go@v3' '') }) 'R6').Count | Should -Be 1
        (Only (Invoke-Rules @{ 'c.yml' = (& $mk 'actions/setup-go@v5' "        with:`n          cache: false`n") }) 'R6').Count | Should -Be 1
        $rs = Invoke-Rules @{ 'd.yml' = (& $mk 'actions/setup-go@0123456789abcdef0123456789abcdef01234567' '') }
        (Only $rs 'R6').Count | Should -Be 0
        (Unm $rs 'R6').Count | Should -Be 1
    }
}

Describe 'R7 - crons' {
    It 'a daily cron is a finding at the cron line; a weekly one is clean; an unreadable one is not measured' {
        $mk = { param($c) "on:`n  schedule:`n    - cron: '$c'`njobs:`n$script:Ok" }
        $daily = Only (Invoke-Rules @{ 'a.yml' = (& $mk '0 9 * * *') }) 'R7'
        $daily.Count | Should -Be 1
        $daily[0].Line | Should -Be 3
        $daily[0].Severity | Should -Be 'medium'
        (Only (Invoke-Rules @{ 'b.yml' = (& $mk '0 9 * * 1') }) 'R7').Count | Should -Be 0
        (Only (Invoke-Rules @{ 'c.yml' = (& $mk '0 * * * *') }) 'R7')[0].Severity | Should -Be 'high'
        $r = Invoke-Rules @{ 'd.yml' = (& $mk '@daily') }
        (Only $r 'R7').Count | Should -Be 0
        (Unm $r 'R7').Count | Should -Be 1
    }
}

Describe 'Fan-out - setup repeated across the jobs one event starts' {
    It 'the same install in two workflows on pull_request is one finding that names BOTH places' {
        $a = "on: pull_request`njobs:`n  test:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - uses: actions/checkout@v4`n      - run: npm ci`n      - run: npm test`n"
        $b = "on: pull_request`njobs:`n  lint:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - uses: actions/checkout@v4`n      - run: |`n          npm ci`n          npm run lint`n"
        $r = Invoke-Rules @{ 'a.yml' = $a; 'b.yml' = $b }
        $f = Only $r 'FAN'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match "'npm ci' se repite en 2 jobs"
        ($f[0].Evidence -join ' ') | Should -Match 'a\.yml:8'
        ($f[0].Evidence -join ' ') | Should -Match 'b\.yml:8'
        $r.PerEvent[0].Runners | Should -Be 2
        $r.PerEvent[0].Workflows | Should -Be 2
    }

    It 'different install commands, or one job, is not fan-out' {
        $a = "on: pull_request`njobs:`n  test:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n"
        $b = "on: pull_request`njobs:`n  lint:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: pip install x`n"
        (Only (Invoke-Rules @{ 'a.yml' = $a; 'b.yml' = $b }) 'FAN').Count | Should -Be 0
        (Only (Invoke-Rules @{ 'a.yml' = $a }) 'FAN').Count | Should -Be 0
    }

    It 'a matrix multiplies the runners and the count says when it is not exact' {
        $a = "on: pull_request`njobs:`n  test:`n    runs-on: `${{ matrix.os }}`n    timeout-minutes: 5`n    strategy:`n      matrix:`n        os: [a, b, c]`n        node: [18, 20]`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'a.yml' = $a }
        $r.PerEvent[0].Runners | Should -Be 6
        $r.PerEvent[0].Exact | Should -BeTrue
        $b = "on: pull_request`njobs:`n  test:`n    if: github.actor != 'bot'`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: x`n"
        $rb = Invoke-Rules @{ 'b.yml' = $b }
        $rb.PerEvent[0].Runners | Should -Be 1
        $rb.PerEvent[0].Exact | Should -BeFalse
    }
}

Describe 'Fan-out on push, and folded scalars' {
    It 'a push-only workflow whose jobs each run the same install is fan-out on push' {
        $y = "on:`n  push:`n    branches: [main]`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n  b:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n"
        $f = Only (Invoke-Rules @{ 'ci.yml' = $y }) 'FAN'
        $f.Count | Should -Be 1
        $f[0].Message | Should -Match 'dispara push'
    }

    It 'a workflow on BOTH pull_request and push is counted once (R1 owns that overlap)' {
        $y = "on: [push, pull_request]`njobs:`n  a:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n  b:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n"
        (Only (Invoke-Rules @{ 'ci.yml' = $y }) 'FAN').Count | Should -Be 1
    }

    It 'workflows whose branch filters cannot overlap are not paid for together; overlapping or unfiltered ones are' {
        $mk = { param($b) "on:`n  push:`n    branches: [$b]`njobs:`n  j:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n" }
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'main'); 'b.yml' = (& $mk 'dev') }) 'FAN').Count | Should -Be 0
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'main'); 'b.yml' = (& $mk 'main') }) 'FAN').Count | Should -Be 1
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'main'); 'b.yml' = (& $mk "'ma*'") }) 'FAN').Count | Should -Be 1
        $any = "on: push`njobs:`n  j:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n"
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'dev'); 'b.yml' = $any }) 'FAN').Count | Should -Be 1
        # a pull_request trigger filters the PR BASE branch, and the same reasoning applies
        $pr = { param($b) "on:`n  pull_request:`n    branches: [$b]`njobs:`n  j:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: npm ci`n" }
        (Only (Invoke-Rules @{ 'a.yml' = (& $pr 'main'); 'b.yml' = (& $pr 'develop') }) 'FAN').Count | Should -Be 0
    }
    It 'a folded run: > whose text merely contains npm ci on a later line is one command, not an install' {
        $mk = { param($n) "on: pull_request`njobs:`n  $n`:`n    runs-on: ubuntu-latest`n    timeout-minutes: 5`n    steps:`n      - run: >`n          echo preparing`n          npm ci`n" }
        (Only (Invoke-Rules @{ 'a.yml' = (& $mk 'a'); 'b.yml' = (& $mk 'b') }) 'FAN').Count | Should -Be 0
    }
}
Describe 'The ledger - nothing is OK by omission' {
    It 'every rule reports what it evaluated, how many findings and how many it could not measure' {
        $y = "on:`n  pull_request:`n  push:`n    branches: [main]`nconcurrency: { group: g, cancel-in-progress: true }`njobs:`n$script:Ok"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        $r.Ledger['R1'].Evaluated | Should -Be 1
        $r.Ledger['R1'].Findings | Should -Be 1
        $r.Ledger['R3'].Evaluated | Should -Be 1
        $r.Ledger['R3'].Findings | Should -Be 0
    }

    It 'a finding quotes the real line of the file at the reported line' {
        $y = "on: pull_request`nconcurrency: { group: g, cancel-in-progress: true }`njobs:`n  slow:`n    runs-on: ubuntu-latest`n    steps:`n      - run: x`n"
        $r = Invoke-Rules @{ 'ci.yml' = $y }
        $f = (Only $r 'R3')[0]
        $f.Line | Should -Be 4
        $f.Snippet | Should -Be 'slow:'
    }
}

Describe 'Usage measurement (the only source of a cost number)' {
    BeforeAll {
        $script:Facts = [pscustomobject]@{ Repo = 'me/app'; Name = 'app'; Owner = 'me'; OwnerType = 'User'; Private = $true; DefaultBranch = 'main'; Archived = $false }
        # Dates are UTC midnights on purpose: a local-time conversion would move 09-01 to 08-31.
        $script:Usage = @{ usageItems = @(
            @{ date = '2026-09-01T00:00:00Z'; product = 'actions'; sku = 'Actions Linux';   quantity = 10;  unitType = 'Minutes';       grossAmount = 0.06; netAmount = 0.0;  repositoryName = 'app' }
            @{ date = '2026-09-01T11:00:00Z'; product = 'actions'; sku = 'Actions Linux';   quantity = 5;   unitType = 'Minutes';       grossAmount = 0.03; netAmount = 0.0;  repositoryName = 'app' }
            @{ date = '2026-09-02T00:00:00Z'; product = 'actions'; sku = 'Actions Windows'; quantity = 20;  unitType = 'Minutes';       grossAmount = 0.2;  netAmount = 0.0;  repositoryName = 'app' }
            @{ date = '2026-09-02T00:00:00Z'; product = 'actions'; sku = 'Actions macOS';   quantity = 2;   unitType = 'Minutes';       grossAmount = 0.16; netAmount = 0.0;  repositoryName = 'app' }
            @{ date = '2026-09-02T00:00:00Z'; product = 'actions'; sku = 'Actions Linux 4-core'; quantity = 7; unitType = 'Minutes';    grossAmount = 0.1;  netAmount = 0.1;  repositoryName = 'app' }
            @{ date = '2026-09-01T00:00:00Z'; product = 'actions'; sku = 'Actions storage'; quantity = 1.5; unitType = 'GigabyteHours'; grossAmount = 0.0005; netAmount = 0.0; repositoryName = 'app' }
            @{ date = '2026-09-03T00:00:00Z'; product = 'actions'; sku = 'Actions Linux';   quantity = 100; unitType = 'Minutes';       grossAmount = 0.6;  netAmount = 0.0;  repositoryName = 'oss-lib' }
            @{ date = '2026-09-03T00:00:00Z'; product = 'actions'; sku = 'Actions Windows'; quantity = 50;  unitType = 'Minutes';       grossAmount = 0.5;  netAmount = 0.0;  repositoryName = 'other-private' }
            @{ date = '2026-09-03T00:00:00Z'; product = 'actions'; sku = 'Actions Linux';   quantity = 40;  unitType = 'Minutes';       grossAmount = 0.24; netAmount = 0.0;  repositoryName = 'gone' }
            @{ date = '2026-09-03T00:00:00Z'; product = 'copilot'; sku = 'Copilot Premium Request'; quantity = 99; unitType = 'Requests'; grossAmount = 1; netAmount = 1; repositoryName = 'app' }
        ) } | ConvertTo-Json -Depth 5
        $script:Route = {
            $a = $GhArgs -join ' '
            $ok = { param($o) [pscustomobject]@{ Output = $o; ExitCode = 0; StdErr = '' } }
            if ($a -match 'settings/billing/usage') { return (& $ok $script:Usage) }
            if ($a -match 'repos/me/oss-lib') { return (& $ok 'false') }
            if ($a -match 'repos/me/other-private') { return (& $ok 'true') }
            return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Not Found (HTTP 404)' }
        }
    }

    It 'sums minutes per SKU and per UTC day, ignoring other products and other repos' {
        Mock Invoke-GhRaw $script:Route
        $u = Get-UsageMeasure $script:Facts '2026-09' 5
        $u.Measured | Should -BeTrue
        $u.RepoMinutes | Should -Be 44
        $u.BySku['Actions Linux'] | Should -Be 15
        $u.BySku['Actions Windows'] | Should -Be 20
        $u.BySku['Actions macOS'] | Should -Be 2
        @($u.ByDay | ForEach-Object { $_.Date }) | Should -Be @('2026-09-01', '2026-09-02')
        $u.ByDay[0].Minutes | Should -Be 15
        $u.ByDay[1].Minutes | Should -Be 29
        $u.StorageGbHours | Should -Be 1.5
        $u.Endpoint | Should -Be 'users/me/settings/billing/usage'
    }

    It 'weights by the documented multiplier and does NOT weigh a SKU it does not know' {
        Mock Invoke-GhRaw $script:Route
        $u = Get-UsageMeasure $script:Facts '2026-09' 5
        # 15 Linux x1 + 20 Windows x2 + 2 macOS x10 = 75; the 4-core larger runner is not weighed
        $u.QuotaWeightedMinutes | Should -Be 75
        $u.UnweightedSkus | Should -Be @('Actions Linux 4-core')
    }

    It 'the account view counts only PRIVATE repos toward the quota and says which visibility it could not read' {
        Mock Invoke-GhRaw $script:Route
        $u = Get-UsageMeasure $script:Facts '2026-09' 5
        $u.AccountMinutes | Should -Be 234
        # app (private, 75) + other-private (50 windows x2 = 100); oss-lib is public; 'gone' is unreadable
        $u.AccountQuotaBearingWeighted | Should -Be 175
        $u.AccountUnknownVisibility | Should -Be @('gone')
        ($u.TopRepos | Where-Object { $_.Repo -eq 'oss-lib' }).Visibility | Should -Be 'public'
        $u.TopRepos[0].Repo | Should -Be 'oss-lib'
    }

    It 'a date is bucketed by its UTC day even when the JSON parser hands back local time' {
        $utc = [datetime]::new(2026, 9, 1, 0, 30, 0, [System.DateTimeKind]::Utc)
        Get-DayKey $utc.ToLocalTime() | Should -Be '2026-09-01'
        Get-DayKey '2026-09-01T00:30:00Z' | Should -Be '2026-09-01'
    }
    It '-Top limits the account list' {
        Mock Invoke-GhRaw $script:Route
        (Get-UsageMeasure $script:Facts '2026-09' 2).TopRepos.Count | Should -Be 2
    }

    It 'an organization is read from the organization endpoint' {
        Mock Invoke-GhRaw $script:Route
        $org = $script:Facts.PSObject.Copy(); $org.OwnerType = 'Organization'
        (Get-UsageMeasure $org '2026-09' 5).Endpoint | Should -Be 'organizations/me/settings/billing/usage'
    }

    It 'a refused endpoint is NOT MEASURED with the reason - there is no zero to read' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Must have admin rights to Repository. (HTTP 403)' } }
        $u = Get-UsageMeasure $script:Facts '2026-09' 5
        $u.Measured | Should -BeFalse
        $u.Reason | Should -Match 'HTTP 403'
        $u.PSObject.Properties.Name | Should -Not -Contain 'RepoMinutes'
    }

    It 'a repo with no usage rows reports measured zero, which is different from not measured' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = '{"usageItems":[]}'; ExitCode = 0; StdErr = '' } }
        $u = Get-UsageMeasure $script:Facts '2026-09' 5
        $u.Measured | Should -BeTrue
        $u.RepoMinutes | Should -Be 0
    }
}

Describe 'The whole audit (engine + real Invoke-Gh, only the process seam mocked)' {
    BeforeAll {
        $script:Ci = @'
name: CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  test:
    name: Pester
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
'@
        $script:Lint = @'
name: Lint
on: pull_request
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: npm ci
'@
        $script:Nightly = "name: Nightly`non:`n  schedule:`n    - cron: '30 2 * * *'`njobs:`n$script:Ok"
        $script:UsageJson = '{"usageItems":[{"date":"2026-09-01T00:00:00Z","product":"actions","sku":"Actions Windows","quantity":30,"unitType":"Minutes","grossAmount":0.3,"netAmount":0,"repositoryName":"app"}]}'
        $script:EngineRoute = {
            $a = $GhArgs -join ' '
            $ok = { param($o) [pscustomobject]@{ Output = $o; ExitCode = 0; StdErr = '' } }
            $fail = { param($m) [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = $m } }
            if ($a -match '^api repos/me/app$') { return (& $ok '{"name":"app","private":true,"default_branch":"main","archived":false,"owner":{"login":"me","type":"User"}}') }
            if ($a -match 'contents/\.github/workflows\?ref=main') {
                return (& $ok '[{"name":"ci.yml","type":"file","path":".github/workflows/ci.yml"},{"name":"lint.yml","type":"file","path":".github/workflows/lint.yml"},{"name":"nightly.yml","type":"file","path":".github/workflows/nightly.yml"},{"name":"README.md","type":"file","path":".github/workflows/README.md"}]')
            }
            if ($a -match 'Accept: application/vnd.github.raw.*ci\.yml') { return (& $ok ($script:Ci -split "`n")) }
            if ($a -match 'Accept: application/vnd.github.raw.*lint\.yml') { return (& $ok ($script:Lint -split "`n")) }
            if ($a -match 'Accept: application/vnd.github.raw.*nightly\.yml') { return (& $ok ($script:Nightly -split "`n")) }
            if ($a -match 'rules/branches/main') { return (& $ok '[{"type":"pull_request"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Pester"}]}}]') }
            if ($a -match 'protection/required_status_checks') { return (& $fail 'gh: Branch not protected (HTTP 404)') }
            if ($a -match 'settings/billing/usage') { return (& $ok $script:UsageJson) }
            return (& $fail "unexpected gh call: $a")
        }
    }

    It 'audits the default branch: findings are traceable, the cost is measured, the observation is not an action' {
        Mock Invoke-GhRaw $script:EngineRoute
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.Source | Should -Be 'branch main on GitHub'
        @($r.Workflows).Count | Should -Be 3                       # README.md is not a workflow
        $r.Cost.Measured | Should -BeTrue
        $r.Cost.RepoMinutes | Should -Be 30
        $r.Cost.QuotaWeightedMinutes | Should -Be 60

        $rules = @($r.Findings | ForEach-Object { $_.Rule } | Select-Object -Unique)
        foreach ($want in @('R1', 'R2', 'R3', 'R5', 'R7', 'FAN', 'R8')) { $rules | Should -Contain $want }

        $r3 = @($r.Findings | Where-Object { $_.Rule -eq 'R3' })[0]
        $r3.File | Should -Be 'ci.yml'
        $r3.Line | Should -Be 8
        $r3.Snippet | Should -Be 'test:'
        (@($r.Findings | Where-Object { $_.Rule -eq 'R5' })[0]).Snippet | Should -Be 'runs-on: windows-latest'
        (@($r.Findings | Where-Object { $_.Rule -eq 'R7' })[0]).Snippet | Should -Match '30 2'

        $r8 = @($r.Findings | Where-Object { $_.Rule -eq 'R8' })[0]
        $r8.Severity | Should -Be 'observation'
        $r8.Message | Should -Match '30 min'
        $r8.Message | Should -Not -Match '(?i)hazlo|cambia a publico|make it public'
    }

    It 'knows the required check: Pester (ci.yml) is required, so the lint workflow is safe to filter and ci.yml is not' {
        Mock Invoke-GhRaw $script:EngineRoute
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.RequiredChecks.Complete | Should -BeTrue
        $r.RequiredChecks.Contexts | Should -Be @('Pester')
        $r4 = @($r.Findings | Where-Object { $_.Rule -eq 'R4' })
        ($r4 | Where-Object { $_.File -eq 'ci.yml' }).Message | Should -Match 'REQUERIDO'
        ($r4 | Where-Object { $_.File -eq 'lint.yml' }).Message | Should -Match 'no puede dejar una PR en deadlock'
    }

    It 'the runners a PR starts are counted from the files, and the repeated install is named' {
        Mock Invoke-GhRaw $script:EngineRoute
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.RunnersPerPr.Runners | Should -Be 2
        $fan = @($r.Findings | Where-Object { $_.Rule -eq 'FAN' })
        $fan.Count | Should -Be 1
        ($fan[0].Evidence -join ' ') | Should -Match 'ci\.yml'
        ($fan[0].Evidence -join ' ') | Should -Match 'lint\.yml'
    }

    It 'a usage endpoint that refuses leaves the cost UNMEASURED (never zero) but the rules still run' {
        Mock Invoke-GhRaw {
            if (($GhArgs -join ' ') -match 'settings/billing/usage') { return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Not Found (HTTP 404)' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.Cost.Measured | Should -BeFalse
        @($r.Unmeasured | Where-Object { $_.Rule -eq 'COST' }).Count | Should -Be 1
        (@($r.Findings | Where-Object { $_.Rule -eq 'R8' })[0]).Message | Should -Match 'no se pudo medir'
        @($r.Findings | Where-Object { $_.Rule -eq 'R3' }).Count | Should -BeGreaterThan 0
    }

    It 'required checks that cannot be read make the trap verdict NOT MEASURED, and the advice stops claiming safety' {
        Mock Invoke-GhRaw {
            $a = $GhArgs -join ' '
            if ($a -match 'rules/branches|protection/required_status_checks') { return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Resource not accessible (HTTP 403)' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.RequiredChecks.Complete | Should -BeFalse
        @($r.Unmeasured | Where-Object { $_.Rule -eq 'TRAP' }).Count | Should -BeGreaterThan 0
        (@($r.Findings | Where-Object { $_.Rule -eq 'R4' -and $_.File -eq 'lint.yml' })[0]).Message | Should -Not -Match 'no puede dejar una PR en deadlock'
    }

    It 'a failure reading ONLY classic branch protection (not a plain 404) also makes the required checks incomplete' {
        Mock Invoke-GhRaw {
            if (($GhArgs -join ' ') -match 'protection/required_status_checks') { return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Upgrade to GitHub Pro or make this repository public (HTTP 403)' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.RequiredChecks.Complete | Should -BeFalse
        $r.RequiredChecks.Reason | Should -Match 'branch protection'
        $r.RequiredChecks.Contexts | Should -Be @('Pester')        # the ruleset half was still read
    }
    It 'the required checks are read even when the repo has only pull_request_target workflows' {
        Mock Invoke-GhRaw {
            $a = $GhArgs -join ' '
            if ($a -match 'contents/\.github/workflows\?ref=main') { return [pscustomobject]@{ Output = '[{"name":"t.yml","type":"file","path":".github/workflows/t.yml"}]'; ExitCode = 0; StdErr = '' } }
            if ($a -match 'Accept: application/vnd.github.raw.*t\.yml') { return [pscustomobject]@{ Output = @('on:', '  pull_request_target:', "    paths: ['src/**']", 'jobs:', '  check:', '    name: Pester', '    runs-on: ubuntu-latest', '    timeout-minutes: 5', '    steps:', '      - run: x'); ExitCode = 0; StdErr = '' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $r.RequiredChecks.Contexts | Should -Be @('Pester')
        @($r.Findings | Where-Object { $_.Rule -eq 'TRAP' }).Count | Should -Be 1
    }
    It 'a repo with no workflows directory is a measured empty audit, not an error' {
        Mock Invoke-GhRaw {
            if (($GhArgs -join ' ') -match 'contents/\.github/workflows') { return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Not Found (HTTP 404)' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        @($r.Workflows).Count | Should -Be 0
        $r.RunnersPerPr | Should -BeNullOrEmpty
    }

    It 'a workflow file that cannot be downloaded is reported, and the other files are still audited' {
        Mock Invoke-GhRaw {
            if (($GhArgs -join ' ') -match 'ci\.yml\?ref' -and ($GhArgs -join ' ') -match 'Accept') { return [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Server Error (HTTP 500)' } }
            & $script:EngineRoute
        }
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        (@($r.Unmeasured | Where-Object { $_.Rule -eq 'PARSE' -and $_.File -eq 'ci.yml' })).Count | Should -Be 1
        @($r.Workflows).Count | Should -Be 2
    }

    It 'an unreadable repo is an error, not an empty report' {
        Mock Invoke-GhRaw { [pscustomobject]@{ Output = ''; ExitCode = 1; StdErr = 'gh: Not Found (HTTP 404)' } }
        { Get-ActionsCostAudit -Repo 'me/nope' -Month '2026-09' } | Should -Throw '*No pude leer el repo*'
    }

    It 'rejects a malformed -Month before touching gh' {
        { Get-ActionsCostAudit -Repo 'me/app' -Month '2026-13' } | Should -Throw '*yyyy-MM*'
    }

    It '-Local audits the working tree, not GitHub, and still asks GitHub for the repo facts' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("abios-cost-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir '.github/workflows') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $dir '.github/workflows/local.yml'), "on: pull_request`njobs:`n  a:`n    runs-on: ubuntu-latest`n    steps:`n      - run: x`n")
            Mock Invoke-GhRaw $script:EngineRoute
            $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09' -Local -Path $dir
            $r.Source | Should -Match 'working tree'
            @($r.Workflows).Count | Should -Be 1
            $r.Workflows[0].File | Should -Be 'local.yml'
            @($r.Findings | Where-Object { $_.Rule -eq 'R3' -and $_.File -eq 'local.yml' }).Count | Should -Be 1
            Should -Not -Invoke Invoke-GhRaw -ParameterFilter { ($GhArgs -join ' ') -match 'contents/' }
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the rule ledger covers every rule, including the parse and cost lines' {
        Mock Invoke-GhRaw $script:EngineRoute
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        @($r.Rules | ForEach-Object { $_.Rule }) | Should -Be @('R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'FAN', 'TRAP', 'PARSE', 'COST')
        ($r.Rules | Where-Object { $_.Rule -eq 'R3' }).Evaluated | Should -Be 3
        ($r.Rules | Where-Object { $_.Rule -eq 'PARSE' }).Evaluated | Should -Be 3
    }

    It 'the report prints without error and never prints a raw script filename' {
        Mock Invoke-GhRaw $script:EngineRoute
        $r = Get-ActionsCostAudit -Repo 'me/app' -Month '2026-09'
        $out = & { Write-ActionsCostReport $r } 6>&1 | Out-String
        $out | Should -Match 'COSTE MEDIDO'
        $out | Should -Match 'LIBRO DE REGLAS'
        $out | Should -Match 'ci\.yml:8'
        $out | Should -Not -Match '\.ps1'
    }
}

Describe 'Read-only by construction' {
    BeforeAll {
        $tokens = $null; $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$tokens, [ref]$errs)
        $script:Cmds = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    }

    It 'contains no raw gh call: every gh goes through Invoke-Gh' {
        @($script:Cmds | Where-Object { $_.GetCommandName() -eq 'gh' }).Count | Should -Be 0
    }

    It 'every Invoke-Gh call is a plain GET api read: no method override, no field, no input body' {
        $calls = @($script:Cmds | Where-Object { $_.GetCommandName() -eq 'Invoke-Gh' })
        $calls.Count | Should -BeGreaterThan 3
        foreach ($c in $calls) {
            $text = $c.Extent.Text
            $text | Should -Match "'api'" -Because "line $($c.Extent.StartLineNumber): only api reads"
            $text | Should -Not -Match "'(-X|--method|-f|-F|--field|--raw-field|--input|POST|PUT|PATCH|DELETE)'" -Because "line $($c.Extent.StartLineNumber): a write flag"
            $text | Should -Not -Match '-StdIn' -Because "line $($c.Extent.StartLineNumber): a request body"
        }
    }

    It 'never writes to disk or to the repo: no file writes, no git' {
        $names = @($script:Cmds | ForEach-Object { $_.GetCommandName() })
        foreach ($bad in @('Set-Content', 'Add-Content', 'Out-File', 'New-Item', 'Remove-Item', 'git')) {
            $names | Should -Not -Contain $bad
        }
        $script:Ast.Extent.Text | Should -Not -Match '\[(System\.)?IO\.File\]::Write'
    }

    It 'never reads the runs timing endpoint or a run timestamp as a cost' {
        $body = ($script:Cmds | Where-Object { $_.GetCommandName() -eq 'Invoke-Gh' } | ForEach-Object { $_.Extent.Text }) -join "`n"
        $body | Should -Not -Match '/timing'
        $body | Should -Not -Match 'actions/runs'
    }
}

Describe 'Command surface - the verb is routed and documented (#614)' {
    BeforeAll {
        $plugin = Join-Path $PSScriptRoot '..' | Resolve-Path
        $script:Board = Get-Content (Join-Path $plugin 'commands' 'board.md') -Raw
        $script:Skill = Get-Content (Join-Path $plugin 'skills' 'projects-admin' 'SKILL.md') -Raw
        $script:RefPath = Join-Path $plugin 'skills' 'projects-admin' 'references' 'verbs-actions-cost.md'
        $script:Plugin = $plugin
    }

    It 'the reference file exists and board.md and SKILL.md route to it' {
        Test-Path -LiteralPath $script:RefPath | Should -BeTrue
        $script:Board | Should -Match 'references/verbs-actions-cost\.md'
        $script:Skill | Should -Match 'references/verbs-actions-cost\.md'
    }

    It 'board.md lists the verb in its description and its menu, and the /board menu does not dress it as a slash command' {
        $script:Board | Should -Match '(?m)^description:.*actions-cost'
        $script:Board | Should -Match '(?m)^\d+\.\s+actions-cost\s+'
        $script:Board | Should -Not -Match '(?m)^\s*/actions-cost'
    }

    It 'the reference names only scripts that exist, and states the two measurement traps and the read-only rule' {
        $ref = Get-Content $script:RefPath -Raw
        foreach ($m in [regex]::Matches($ref, '(?<![\w.-])([A-Z][A-Za-z]+-[A-Za-z]+)\.ps1')) {
            Test-Path -LiteralPath (Join-Path $script:Plugin 'scripts' $m.Value) | Should -BeTrue -Because "$($m.Value) is named in verbs-actions-cost.md"
        }
        $ref | Should -Match 'Get-ActionsCostAudit\.ps1'
        $ref | Should -Match '/timing'
        $ref | Should -Match '(?i)wall-clock'
        $ref | Should -Match '(?i)read-only'
        $ref | Should -Match '(?i)not measured'
    }
}
