#Requires -Modules Pester
<#  New-BoardPR.ps1 -IssueRepo (#487): a PR opened in ANOTHER repo for an issue that lives elsewhere
    must reference the issue as `Refs owner/name#n`. A bare `Closes #n` there would close THAT
    repository's own issue n. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'New-BoardPR.ps1' | Resolve-Path
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = '1'
    . $script:Script -Issue 1              # -Issue is Mandatory; the guard returns before it is used
    $env:ABIOS_NEWBOARDPR_DOTSOURCE = ''
}

Describe 'New-BoardPR: a cross-repo PR says Refs, never Closes' {
    It 'keeps the classic Closes body when no issue repo is given' {
        Format-ClosesBody -Issues @(271) | Should -Be 'Closes #271'
    }
    It 'writes a qualified Refs line per issue for an issue in another repo' {
        $b = Format-ClosesBody -Issues @(271, 272) -IssueRepo 'home/site' -Extra 'extra'
        $b | Should -Match 'Refs home/site#271'
        $b | Should -Match 'Refs home/site#272'
        $b | Should -Not -Match 'Closes'
        $b | Should -Match 'extra'
    }
}

Describe 'Get-IssueHomeRepo' {
    It 'reads the issue from the PR repo by default and from -IssueRepo when given' {
        Get-IssueHomeRepo -Repo 'o/target' | Should -Be 'o/target'
        Get-IssueHomeRepo -Repo 'o/target' -IssueRepo 'home/site' | Should -Be 'home/site'
    }
}
