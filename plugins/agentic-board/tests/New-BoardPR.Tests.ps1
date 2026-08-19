#Requires -Modules Pester
<#  Tests for New-BoardPR.ps1's pure PR-existence check (#336).

    New-BoardPR.ps1 is side-effecting (git push + gh pr create), so it exposes a dot-source guard:
    with $env:ABIOS_NEWBOARDPR_DOTSOURCE set it returns after defining the pure helper. The bug was
    `@($existing).Count -gt 0`: a phantom read row with a null `.number` counted as "PR exists", so
    `gh pr create` was skipped and the run reported success with a BLANK PR number. Get-ExistingPr
    treats a PR as existing only when the row carries a positive-integer number. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'New-BoardPR.ps1' | Resolve-Path
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = '1'
    . $script:Script -Issue 1              # -Issue is Mandatory; the guard returns before it is used
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = ''
}

Describe 'Get-ExistingPr — a phantom row is not an existing PR (#336)' {
    It 'returns nothing for an empty read ([] -> create path)' {
        Get-ExistingPr @() | Should -BeNullOrEmpty
    }
    It 'returns nothing for a null read' {
        Get-ExistingPr $null | Should -BeNullOrEmpty
    }
    It 'ignores a phantom row with a null number (the bug: it skipped create and printed a blank PR)' {
        Get-ExistingPr @([pscustomobject]@{ number = $null; url = '' }) | Should -BeNullOrEmpty
    }
    It 'ignores a row whose number is zero' {
        Get-ExistingPr @([pscustomobject]@{ number = 0; url = 'x' }) | Should -BeNullOrEmpty
    }
    It 'returns the first genuine PR row (positive number -> iterate path)' {
        $r = Get-ExistingPr @([pscustomobject]@{ number = 42; url = 'https://x/42' })
        $r.number | Should -Be 42
    }
    It 'skips a leading phantom and returns the real PR behind it' {
        $r = Get-ExistingPr @(
            [pscustomobject]@{ number = $null; url = '' },
            [pscustomobject]@{ number = 7;     url = 'https://x/7' }
        )
        $r.number | Should -Be 7
    }
}

Describe 'Get-IssueNumbers — batch -Issue parsing (#633)' {
    It 'passes through a native int array' {
        (Get-IssueNumbers @(631, 632)) | Should -Be @(631, 632)
    }
    It 'splits a single comma-separated string (the pwsh -File flattening case)' {
        (Get-IssueNumbers '631,632') | Should -Be @(631, 632)
    }
    It 'trims whitespace around commas' {
        (Get-IssueNumbers '631, 632 ,633') | Should -Be @(631, 632, 633)
    }
    It 'dedupes while preserving first-seen order' {
        (Get-IssueNumbers @('631,632,631')) | Should -Be @(631, 632)
    }
    It 'drops non-positive and non-numeric tokens' {
        (Get-IssueNumbers @('0,-3,abc,632')) | Should -Be @(632)
    }
    It 'returns an empty array for no valid tokens' {
        @(Get-IssueNumbers @('abc,0')).Count | Should -Be 0
    }
}

Describe 'Format-ClosesBody — one Closes line per issue, extra body appended (#633)' {
    It 'formats a single issue exactly like the pre-#633 behavior' {
        Format-ClosesBody -Issues @(13) | Should -Be "Closes #13"
    }
    It 'formats one Closes line per issue in the given order' {
        Format-ClosesBody -Issues @(631, 632) | Should -Be "Closes #631`nCloses #632"
    }
    It 'appends extra body text after a blank line' {
        Format-ClosesBody -Issues @(13) -Extra 'Some context.' | Should -Be "Closes #13`n`nSome context."
    }
    It 'omits the blank-line separator when there is no extra body' {
        Format-ClosesBody -Issues @(13) -Extra '' | Should -Be "Closes #13"
    }
}
