#Requires -Modules Pester
<#  Tests for Expert-Evidence.ps1 — the recorded test-evidence the auto-expert leaves behind.

    Pure formatting behind ABIOS_EXPERTEVIDENCE_DOTSOURCE. These pin the durable [abios-evidence]
    marker, the pass/fail summary, one table row per test run, and the contract-driven choice of
    destinations (PR body / issue comment / versioned file). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-Evidence.ps1' | Resolve-Path
    $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE = ''
    $script:Results = @(
        @{ name = 'Pester Board-Plan'; command = 'Invoke-Pester Board-Plan'; result = 'PASS'; detail = '5 passed' },
        @{ name = 'Pester contract';   command = 'Invoke-Pester ExpertContractIo'; result = 'PASS'; detail = '7 passed' },
        @{ name = 'lint';              command = 'PSScriptAnalyzer'; result = 'FAIL'; detail = '1 warning' }
    )
}

Describe 'Format-EvidenceBlock' {
    It 'carries the durable [abios-evidence] marker' {
        Format-EvidenceBlock -Results $script:Results | Should -Match '\[abios-evidence\]'
    }
    It 'summarizes the pass/fail counts' {
        $b = Format-EvidenceBlock -Results $script:Results
        $b | Should -Match '2 passed'
        $b | Should -Match '1 failed'
    }
    It 'renders one table row per result' {
        $b = Format-EvidenceBlock -Results $script:Results
        $b | Should -Match 'Pester Board-Plan'
        $b | Should -Match 'PSScriptAnalyzer'
        # a markdown table row per result (lines starting with '| ' beyond the header/separator)
        ($b -split "`n" | Where-Object { $_ -match '^\|' }).Count | Should -BeGreaterOrEqual 5  # header + sep + 3 rows
    }
    It 'handles an empty result set without crashing' {
        Format-EvidenceBlock -Results @() | Should -Match '0 passed'
    }
}

Describe 'Get-EvidenceTargets' {
    It 'returns all three when the contract enables them' {
        $c = @{ evidence = @{ pr = $true; issueComment = $true; file = $true } }
        $t = Get-EvidenceTargets -Contract $c
        $t | Should -Contain 'pr'; $t | Should -Contain 'issueComment'; $t | Should -Contain 'file'
    }
    It 'omits a disabled destination' {
        $c = @{ evidence = @{ pr = $true; issueComment = $true; file = $false } }
        $t = Get-EvidenceTargets -Contract $c
        $t | Should -Not -Contain 'file'
        $t | Should -Contain 'pr'
    }
}

Describe 'Format-EvidenceLinkStub - one source of truth, two pointers (#570)' {
    It 'carries the marker, the summary and the linked path on the DURABLE base branch' {
        # Base branch, not PR branch: the merge flow deletes the PR branch, and the comment is
        # the record that outlives it (round 3).
        $s = Format-EvidenceLinkStub -Issue 42 -Results @(@{ result = 'PASS' }, @{ result = 'PASS' }, @{ result = 'FAIL' }) -Repo 'o/r' -BaseBranch 'main'
        $s | Should -Match '\[abios-evidence\]'
        $s | Should -Match '2 passed / 1 failed'
        $s | Should -Match 'https://github.com/o/r/blob/main/evidence/42.md'
    }
    It 'falls back to the plain path when repo/branch are unknown' {
        $s = Format-EvidenceLinkStub -Issue 7
        $s | Should -Match 'evidence/7\.md'
        $s | Should -Not -Match 'https://'
    }
}
