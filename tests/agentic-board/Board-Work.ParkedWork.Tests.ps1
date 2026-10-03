#Requires -Modules Pester
<#  Tests for the parked-work ledger in the /board work state of play (#735).

    `/cleanup sessions` parks unmerged work as a DRAFT PR labelled `parked`, so the default
    branch knows it exists without merging it. That is only half a ledger: the other half is that
    `/board work` - the command you run to pick up work - SHOWS it first, with what it is and how to
    resume it. Otherwise parked work is just another draft PR nobody remembers. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Board-Work.ps1' | Resolve-Path
    $env:ABIOS_BOARDWORK_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_BOARDWORK_DOTSOURCE = ''

    function New-Pr {
        param([int]$Number, [string]$Branch, [string[]]$Labels = @(), [bool]$Draft = $true, [string]$Title = '')
        [pscustomobject]@{
            number = $Number; headRefName = $Branch; isDraft = $Draft
            title = $(if ($Title) { $Title } else { "WIP (parked): $Branch" })
            labels = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
        }
    }
}

Describe 'Get-ParkedWorkFindings - parked work is listed, with how to resume it' {
    It 'lists every PR labelled parked, oldest first, with its branch' {
        $f = @(Get-ParkedWorkFindings -Prs @(
            (New-Pr 12 'issue-42-fix-x' @('parked')), (New-Pr 9 'feature-y' @('parked', 'chore')), (New-Pr 15 'other' @('bug'))
        ))
        $f.Count | Should -Be 1
        $f[0].Group | Should -Be 'parked'
        $f[0].Text | Should -Match '2 '
        $f[0].Text | Should -Match 'PR #9.*feature-y'
        $f[0].Text | Should -Match 'PR #12.*issue-42-fix-x'
        $f[0].Text.IndexOf('#9') | Should -BeLessThan $f[0].Text.IndexOf('#12')
        $f[0].Text | Should -Not -Match '#15'
    }
    It 'names the issue a parked branch belongs to' {
        (@(Get-ParkedWorkFindings -Prs @(New-Pr 12 'issue-42-fix-x' @('parked'))))[0].Text | Should -Match 'issue #42'
    }
    It 'says how to resume it, and offers to do it' {
        $f = (@(Get-ParkedWorkFindings -Prs @(New-Pr 12 'issue-42-fix-x' @('parked'))))[0]
        $f.Text | Should -Match 'git switch issue-42-fix-x'
        $f.Offer | Should -Not -BeNullOrEmpty
    }
    It 'matches the label case-insensitively' {
        @(Get-ParkedWorkFindings -Prs @(New-Pr 3 'a' @('Parked'))).Count | Should -Be 1
    }
    It 'says nothing when there is no parked work' {
        @(Get-ParkedWorkFindings -Prs @((New-Pr 1 'a' @('bug')), (New-Pr 2 'b'))) | Should -BeNullOrEmpty
        @(Get-ParkedWorkFindings -Prs @()) | Should -BeNullOrEmpty
    }
}

Describe 'Get-OpenPrFindings - a parked PR is not counted twice' {
    It 'leaves parked PRs out of the generic open-PR line' {
        $f = @(Get-OpenPrFindings -Prs @((New-Pr 1 'a' @('parked')), (New-Pr 2 'b' @('bug') $false)))
        $f.Count | Should -Be 1
        $f[0].Text | Should -Match '^1 open PR'
        $f[0].Text | Should -Not -Match 'PR #1 '
    }
    It 'says nothing about open PRs when every open PR is parked (the parked group already did)' {
        @(Get-OpenPrFindings -Prs @(New-Pr 1 'a' @('parked'))) | Should -BeNullOrEmpty
    }
}

Describe 'Format-StateOfPlay - parked work comes first' {
    It 'prints the parked group before "In flight"' {
        $findings = @(
            (New-StateFinding -Source 'pr' -Group 'inflight' -Text '1 open PR(s): PR #2.')
            (New-StateFinding -Source 'parked' -Group 'parked' -Text '1 piece(s) of work parked: PR #1.' -Offer 'resume one')
        )
        $text = @(Format-StateOfPlay -Findings $findings -Repo 'o/r' | ForEach-Object Text)
        $iParked = [array]::IndexOf($text, @($text | Where-Object { $_ -match 'Parked' -and $_ -match ':$' })[0])
        $iFlight = [array]::IndexOf($text, '  In flight:')
        $iParked | Should -BeGreaterThan 0
        $iParked | Should -BeLessThan $iFlight
    }
    It 'parked work alone makes the repo not clean' {
        Test-StateOfPlayClean @(New-StateFinding -Source 'parked' -Group 'parked' -Text 'x') | Should -BeFalse
    }
}
