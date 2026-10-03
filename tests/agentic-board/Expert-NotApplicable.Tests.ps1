#Requires -Modules Pester
<#  Tests for the honest evidence states and the repo-derived DoD (#475, #481).

    #475: the contract's definition of done carried semantic-model gates (bpa, tmdlBreaking) into
    repos that have no semantic model, and the evidence block had only PASS and FAIL - so a gate
    that did not apply could only be recorded as a lie (PASS) or omitted. Two halves:

      1. the DEFAULT contract is derived from what the repo contains, in BOTH directions (no model
         -> no bpa/tmdlBreaking; a model -> both), and an unreadable repo keeps the gates;
      2. the evidence block has two more honest states - N/A (does not apply to this change) and
         NOT-EVALUATED (applies, but CI never ran) - each counted separately in the summary and
         NEVER folded into passed.

    Filesystem detection is driven against real temp directories, including a real `git init` so
    the git-based path and the directory-walk fallback are both exercised. #>

BeforeAll {
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path

    $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'ExpertContractIo.ps1')
    $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = ''

    $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE = '1'
    . (Join-Path $script:Scripts 'Expert-Evidence.ps1')
    $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE = ''

    function script:New-TempRepo([string[]]$Files, [switch]$Git) {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("abios-repo-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        foreach ($f in $Files) {
            $p = Join-Path $d $f
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            Set-Content -LiteralPath $p -Value 'x'
        }
        if ($Git) { & git -C $d init -q 2>$null | Out-Null }
        $d
    }
}

Describe 'Test-RepoHasSemanticModel (#475)' {
    It 'a repo with no model file has none (the reported case: a TypeScript / VS Code repo)' {
        $d = script:New-TempRepo -Files 'src/index.ts', 'package.json', 'README.md' -Git
        try { Test-RepoHasSemanticModel -Root $d | Should -BeFalse } finally { Remove-Item $d -Recurse -Force }
    }
    It 'a .tmdl file (PBIP semantic model) is detected, at any depth' {
        $d = script:New-TempRepo -Files 'Sales.SemanticModel/definition/tables/Sales.tmdl' -Git
        try { Test-RepoHasSemanticModel -Root $d | Should -BeTrue } finally { Remove-Item $d -Recurse -Force }
    }
    It 'a .bim and a .pbism are detected too' {
        foreach ($f in 'model.bim', 'x/definition.pbism') {
            $d = script:New-TempRepo -Files $f -Git
            try { Test-RepoHasSemanticModel -Root $d | Should -BeTrue -Because $f } finally { Remove-Item $d -Recurse -Force }
        }
    }
    It 'the directory-walk fallback (not a git repo) agrees in both directions' {
        $none = script:New-TempRepo -Files 'a.ts'
        $has  = script:New-TempRepo -Files 'sub/m.tmdl'
        try {
            Test-RepoHasSemanticModel -Root $none | Should -BeFalse
            Test-RepoHasSemanticModel -Root $has  | Should -BeTrue
        } finally { Remove-Item $none, $has -Recurse -Force }
    }
    It 'a model under node_modules or .git is not the repo''s own model (walk fallback)' {
        $d = script:New-TempRepo -Files 'node_modules/pkg/fixture.tmdl', '.git/x/y.tmdl', 'src/a.ts'
        try { Test-RepoHasSemanticModel -Root $d | Should -BeFalse } finally { Remove-Item $d -Recurse -Force }
    }
    It 'a model that is untracked but not ignored counts (added this session)' {
        $d = script:New-TempRepo -Files 'm.tmdl' -Git
        try { Test-RepoHasSemanticModel -Root $d | Should -BeTrue } finally { Remove-Item $d -Recurse -Force }
    }
    It 'FAILS OPEN to "has a model" when the root cannot be read - could not look never waives a gate' {
        Test-RepoHasSemanticModel -Root (Join-Path ([System.IO.Path]::GetTempPath()) ('missing-' + [guid]::NewGuid().ToString('N'))) |
            Should -BeTrue
    }
}

Describe 'New-ExpertContract / Read-ExpertContract - the DoD follows the repo (#475)' {
    It 'no semantic model: the default DoD carries ci/build/lint/tests and NOT bpa/tmdlBreaking' {
        $dod = (New-ExpertContract -HasSemanticModel $false).dod
        foreach ($k in 'ci', 'build', 'lint', 'tests') { $dod.ContainsKey($k) | Should -BeTrue -Because $k }
        $dod.ContainsKey('bpa')          | Should -BeFalse
        $dod.ContainsKey('tmdlBreaking') | Should -BeFalse
    }
    It 'with a semantic model: it still gets both - the guard for the other direction' {
        $dod = (New-ExpertContract -HasSemanticModel $true).dod
        $dod.bpa          | Should -BeTrue
        $dod.tmdlBreaking | Should -BeTrue
    }
    It 'a caller that never looked keeps the full set (the safe default)' {
        (New-ExpertContract).dod.ContainsKey('bpa') | Should -BeTrue
    }
    It 'reading a contract that omits them in a non-model repo does NOT re-add them' {
        $repo = script:New-TempRepo -Files 'src/a.ts' -Git
        $f = Join-Path $repo 'expert.json'
        '{ "role": "r" }' | Set-Content -LiteralPath $f -Encoding utf8
        try {
            $c = Read-ExpertContract -Path $f -Root $repo
            $c.dod.ContainsKey('bpa')          | Should -BeFalse
            $c.dod.ContainsKey('tmdlBreaking') | Should -BeFalse
            $c.dod.ci | Should -BeTrue
        } finally { Remove-Item $repo -Recurse -Force }
    }
    It 'reading a contract that omits them in a MODEL repo fills both in' {
        $repo = script:New-TempRepo -Files 'Sales.SemanticModel/t.tmdl' -Git
        $f = Join-Path $repo 'expert.json'
        '{ "role": "r" }' | Set-Content -LiteralPath $f -Encoding utf8
        try {
            $c = Read-ExpertContract -Path $f -Root $repo
            $c.dod.bpa          | Should -BeTrue
            $c.dod.tmdlBreaking | Should -BeTrue
        } finally { Remove-Item $repo -Recurse -Force }
    }
    It 'an explicit on-disk value always wins over the derived default (owner turned bpa off in a model repo)' {
        $repo = script:New-TempRepo -Files 't.tmdl' -Git
        $f = Join-Path $repo 'expert.json'
        '{ "dod": { "bpa": false } }' | Set-Content -LiteralPath $f -Encoding utf8
        try { (Read-ExpertContract -Path $f -Root $repo).dod.bpa | Should -BeFalse } finally { Remove-Item $repo -Recurse -Force }
    }
}

Describe 'Expert-Config New-ExpertConfig carries the repo signal into the contract (#475)' {
    BeforeAll {
        $env:ABIOS_EXPERTCONFIG_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Expert-Config.ps1')
        $env:ABIOS_EXPERTCONFIG_DOTSOURCE = ''
    }
    It 'HasSemanticModel:$false drops the two model gates from the written contract' {
        $c = New-ExpertConfig -PlanText 'ship a typescript extension' -PlanGoal 'g' -HasSemanticModel $false
        $c.dod.ContainsKey('bpa')          | Should -BeFalse
        $c.dod.ContainsKey('tmdlBreaking') | Should -BeFalse
    }
    It 'HasSemanticModel:$true keeps them' {
        $c = New-ExpertConfig -PlanText 'power bi model' -PlanGoal 'g' -HasSemanticModel $true
        $c.dod.bpa | Should -BeTrue
        $c.dod.tmdlBreaking | Should -BeTrue
    }
}

Describe 'Get-EvidenceState - the four honest outcomes (#475, #481)' {
    It 'maps PASS/FAIL as before, case-insensitively' {
        Get-EvidenceState -Result 'pass' | Should -Be 'pass'
        Get-EvidenceState -Result 'FAIL' | Should -Be 'fail'
    }
    It 'accepts the written forms of not applicable' {
        foreach ($r in 'N/A', 'n/a', 'NA', 'not applicable', 'NOT-APPLICABLE', 'not_applicable') {
            Get-EvidenceState -Result $r | Should -Be 'na' -Because $r
        }
    }
    It 'accepts the written forms of not evaluated' {
        foreach ($r in 'NOT-EVALUATED', 'not evaluated', 'not_evaluated') {
            Get-EvidenceState -Result $r | Should -Be 'not-evaluated' -Because $r
        }
    }
    It 'an unrecognised result is left uncounted, never forced into pass' {
        Get-EvidenceState -Result 'PARTIAL' | Should -Be ''
        Get-EvidenceState -Result '' | Should -Be ''
    }
}

Describe 'Format-EvidenceBlock / Format-EvidenceLinkStub - N/A and not-evaluated are their own counts' {
    BeforeAll {
        $script:Rows = @(
            @{ name = 'tests'; command = 'Invoke-Pester'; result = 'PASS';          detail = '9 passed' },
            @{ name = 'lint';  command = 'PSSA';          result = 'FAIL';          detail = '1 warning' },
            @{ name = 'bpa';   command = '(gate does not apply to this change)'; result = 'N/A'; detail = 'no semantic-model file' },
            @{ name = 'ci';    command = 'gh pr checks';  result = 'NOT-EVALUATED'; detail = 'startup_failure' }
        )
    }
    It 'summarises all four, with N/A and not-evaluated kept OUT of passed' {
        $b = Format-EvidenceBlock -Results $script:Rows
        $b | Should -Match '\*\*Summary:\*\* 1 passed / 1 failed / 1 not applicable / 1 not evaluated'
    }
    It 'renders the N/A and NOT-EVALUATED rows verbatim in the table' {
        $b = Format-EvidenceBlock -Results $script:Rows
        $b | Should -Match '\| bpa \|.*\| N/A \|'
        $b | Should -Match '\| ci \|.*\| NOT-EVALUATED \|'
    }
    It 'the link stub carries the same four-way summary' {
        Format-EvidenceLinkStub -Issue 5 -Results $script:Rows | Should -Match '1 passed / 1 failed / 1 not applicable / 1 not evaluated'
    }
    It 'a run that never needed the new states produces the SAME summary line as before (nothing that parses it moves)' {
        $b = Format-EvidenceBlock -Results @(@{ result = 'PASS' }, @{ result = 'PASS' }, @{ result = 'FAIL' })
        $b | Should -Match '\*\*Summary:\*\* 2 passed / 1 failed\r?\n'
        $b | Should -Not -Match 'not applicable'
        $b | Should -Not -Match 'not evaluated'
    }
    It 'a N/A row is never counted as a pass' {
        $b = Format-EvidenceBlock -Results @(@{ result = 'N/A' }, @{ result = 'NOT-EVALUATED' })
        $b | Should -Match '0 passed / 0 failed / 1 not applicable / 1 not evaluated'
    }
}

Describe 'Get-NotApplicableGateRows - the gates the contract enabled but the diff does not owe (#475)' {
    BeforeAll {
        $script:Dod = @{ ci = $true; build = $true; lint = $true; tests = $true; bpa = $true; tmdlBreaking = $true }
    }
    It 'a code-only diff records bpa and tmdlBreaking as N/A, each with the reason' {
        $rows = @(Get-NotApplicableGateRows -Dod $script:Dod -ChangedPaths @('src/app.ps1'))
        ($rows | ForEach-Object { $_.name } | Sort-Object) | Should -Be @('bpa', 'tmdlBreaking')
        foreach ($r in $rows) {
            $r.result | Should -Be 'N/A'
            $r.detail | Should -Match 'semantic-model'
        }
    }
    It 'a docs-only diff records build/lint/tests/bpa/tmdlBreaking as N/A but never ci' {
        $rows = @(Get-NotApplicableGateRows -Dod $script:Dod -ChangedPaths @('README.md'))
        ($rows | ForEach-Object { $_.name }) | Should -Not -Contain 'ci'
        ($rows | ForEach-Object { $_.name }) | Should -Contain 'tests'
        ($rows | ForEach-Object { $_.name }) | Should -Contain 'bpa'
    }
    It 'a model diff owes bpa/tmdlBreaking, so they are NOT N/A - the other direction' {
        $rows = @(Get-NotApplicableGateRows -Dod $script:Dod -ChangedPaths @('m/t.tmdl'))
        ($rows | ForEach-Object { $_.name }) | Should -Not -Contain 'bpa'
        ($rows | ForEach-Object { $_.name }) | Should -Not -Contain 'tmdlBreaking'
    }
    It 'an unreadable diff (no paths) produces NO N/A rows: could not see what changed excuses nothing' {
        @(Get-NotApplicableGateRows -Dod $script:Dod -ChangedPaths @()).Count | Should -Be 0
    }
    It 'a gate the contract turned off is not invented as an N/A row' {
        $dod = @{ ci = $true; bpa = $false }
        @(Get-NotApplicableGateRows -Dod $dod -ChangedPaths @('src/a.ps1')).Count | Should -Be 0
    }
    It 'the rows feed straight into the block and land under not applicable' {
        $rows = @(Get-NotApplicableGateRows -Dod $script:Dod -ChangedPaths @('src/app.ps1'))
        Format-EvidenceBlock -Results $rows | Should -Match '2 not applicable'
    }
}

Describe 'Get-CiEvidenceRow - the CI gate records which of the states applied (#481)' {
    It 'passed -> PASS' {
        (Get-CiEvidenceRow -CiState 'passed').result | Should -Be 'PASS'
    }
    It 'failed -> FAIL, naming the failing checks' {
        $r = Get-CiEvidenceRow -CiState 'failed' -Checks @('Pester')
        $r.result | Should -Be 'FAIL'
        $r.detail | Should -Match 'Pester'
    }
    It 'not-evaluated -> NOT-EVALUATED, and says it is not a failure of the change' {
        $r = Get-CiEvidenceRow -CiState 'not-evaluated' -Checks @('claude-review')
        $r.result | Should -Be 'NOT-EVALUATED'
        $r.detail | Should -Match 'never executed'
        $r.detail | Should -Match 'claude-review'
    }
    It 'the three states are distinct rows, and only PASS counts as passed' {
        $rows = @('passed', 'failed', 'not-evaluated') | ForEach-Object { Get-CiEvidenceRow -CiState $_ }
        ($rows | ForEach-Object { $_.result } | Sort-Object -Unique).Count | Should -Be 3
        Format-EvidenceBlock -Results $rows | Should -Match '1 passed / 1 failed / 1 not evaluated'
    }
    It 'none -> N/A; pending and unreadable produce NO row (not settled facts, recording one would invent it)' {
        (Get-CiEvidenceRow -CiState 'none').result | Should -Be 'N/A'
        Get-CiEvidenceRow -CiState 'pending'    | Should -BeNullOrEmpty
        Get-CiEvidenceRow -CiState 'unreadable' | Should -BeNullOrEmpty
        Get-CiEvidenceRow -CiState ''           | Should -BeNullOrEmpty
    }
}

Describe 'Get-CiEvidence (Expert-EndToEnd) exposes the state without loosening `passed` (#481)' {
    BeforeAll {
        $env:ABIOS_ENDTOEND_DOTSOURCE = '1'
        . (Join-Path $script:Scripts 'Expert-EndToEnd.ps1')
        $env:ABIOS_ENDTOEND_DOTSOURCE = ''
    }
    It 'a startup_failure CI is state not-evaluated and NEVER passed' {
        $e = Get-CiEvidence -ChecksJson '[{"name":"CI","bucket":"fail","state":"STARTUP_FAILURE"}]'
        $e.state  | Should -Be 'not-evaluated'
        $e.passed | Should -BeFalse
    }
    It 'a bucket-pass check whose state is STARTUP_FAILURE is not-evaluated and NOT passed (review thread)' {
        $e = Get-CiEvidence -ChecksJson '[{"name":"CI","bucket":"pass","state":"STARTUP_FAILURE"}]'
        $e.state  | Should -Be 'not-evaluated'
        $e.passed | Should -BeFalse
        (Test-CiChecksPassed -ChecksJson '[{"name":"CI","bucket":"pass","state":"STARTUP_FAILURE"}]') | Should -BeFalse
    }
    It '`passed` still agrees with the old bucket rule everywhere else: pass+skipping true; skipping-only, pending, unknown, cancel false' {
        (Get-CiEvidence -ChecksJson '[{"bucket":"pass","name":"a"},{"bucket":"skipping","name":"b"}]').passed | Should -BeTrue
        foreach ($b in 'skipping', 'pending', 'weird', 'cancel', 'fail') {
            (Get-CiEvidence -ChecksJson ('[{"bucket":"pass","name":"a"},{"bucket":"' + $b + '","name":"b"}]')).passed |
                Should -Be ($b -eq 'skipping') -Because $b
        }
        (Get-CiEvidence -ChecksJson '[{"bucket":"skipping","name":"a"}]').passed | Should -BeFalse
    }
    It 'a real failure is state failed' {
        (Get-CiEvidence -ChecksJson '[{"name":"a","bucket":"pass"},{"name":"b","bucket":"fail","state":"FAILURE"}]').state | Should -Be 'failed'
    }
    It 'green is passed; empty is none; a failed read is unreadable' {
        $g = Get-CiEvidence -ChecksJson '[{"name":"a","bucket":"pass"}]'
        $g.state | Should -Be 'passed'; $g.passed | Should -BeTrue
        (Get-CiEvidence -ChecksJson '').state | Should -Be 'none'
        (Get-CiEvidence -ChecksJson '' -ExitCode 1).state | Should -Be 'unreadable'
    }
}
