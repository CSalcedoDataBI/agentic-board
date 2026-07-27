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
