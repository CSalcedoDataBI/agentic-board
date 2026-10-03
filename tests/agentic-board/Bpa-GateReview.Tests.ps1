#Requires -Modules Pester
<#  Tests for Bpa-GateReview.ps1's pure BPA logic (M3.3, issue #16).

    Bpa-GateReview.ps1 is side-effecting (runs gh + Tabular Editor), so it exposes a dot-source guard:
    with $env:ABIOS_BPA_DOTSOURCE set it returns after defining the pure helpers. These tests pin the
    two decisions the gate depends on: parsing Tabular Editor's GitHub-annotation output into severity
    counts, and turning those counts into a block/pass verdict for a given -FailOn level. The actual
    TE invocation and the safe-skip paths (no model / no rules / no tool) are integration behavior. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Bpa-GateReview.ps1' | Resolve-Path
    $env:ABIOS_BPA_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BPA_DOTSOURCE = ''
}

Describe 'ConvertFrom-BpaAnnotations (TE GitHub-annotation output)' {
    It 'counts error / warning / notice lines and ignores noise' {
        $lines = @(
            'TabularEditor CLI starting...',
            '::error file=Model.tmdl,line=3::Measures must not use FILTER',
            '::warning::Column [x] has no description',
            '::notice::Consider a display folder',
            '::error title=Perf::Avoid bi-directional relationships',
            'Done. 3 issues.'
        )
        $r = ConvertFrom-BpaAnnotations $lines
        $r.error   | Should -Be 2
        $r.warning | Should -Be 1
        $r.info    | Should -Be 1   # notice -> info
        $r.findings.Count | Should -Be 4
    }
    It 'is empty on output with no annotations' {
        $r = ConvertFrom-BpaAnnotations @('nothing to see', 'BPA passed')
        $r.error | Should -Be 0; $r.warning | Should -Be 0; $r.info | Should -Be 0
        $r.findings | Should -BeNullOrEmpty
    }
    It 'captures the message text after the annotation prefix' {
        $r = ConvertFrom-BpaAnnotations @('::error::Do not use calculated columns here')
        $r.findings[0].message | Should -Be 'Do not use calculated columns here'
        $r.findings[0].severity | Should -Be 'error'
    }
    It 'tolerates an empty / null input' {
        (ConvertFrom-BpaAnnotations @()).error | Should -Be 0
    }
}

Describe 'Get-BpaVerdict (block/pass by -FailOn)' {
    It 'blocks on an error when -FailOn error (the gate default)' {
        $v = Get-BpaVerdict ([pscustomobject]@{ error = 2; warning = 1; info = 0 }) 'error'
        $v.Blocked | Should -BeTrue
        $v.Reason  | Should -Match '2 error'
    }
    It 'passes with only warnings when -FailOn error' {
        (Get-BpaVerdict ([pscustomobject]@{ error = 0; warning = 5; info = 0 }) 'error').Blocked | Should -BeFalse
    }
    It 'blocks on a warning when -FailOn warning (stricter)' {
        (Get-BpaVerdict ([pscustomobject]@{ error = 0; warning = 1; info = 0 }) 'warning').Blocked | Should -BeTrue
    }
    It 'never blocks when -FailOn none (warn-only), even with errors' {
        (Get-BpaVerdict ([pscustomobject]@{ error = 9; warning = 9; info = 9 }) 'none').Blocked | Should -BeFalse
    }
    It 'passes a clean model' {
        (Get-BpaVerdict ([pscustomobject]@{ error = 0; warning = 0; info = 0 }) 'error').Blocked | Should -BeFalse
    }
}
