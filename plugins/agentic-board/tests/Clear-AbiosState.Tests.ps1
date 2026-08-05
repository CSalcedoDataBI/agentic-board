#Requires -Modules Pester
<#  Tests for Clear-AbiosState.ps1 — the .agentic-board/ garbage collector (#574).

    The state dir accumulated 48 files across the project's entire life because nothing ever
    cleaned it. These pin the reap plan's THREE rules: only regenerable shapes are ever reaped,
    live sessions protect their files at any age, and durable/unrecognized files never leave. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Clear-AbiosState.ps1' | Resolve-Path
    $env:ABIOS_CLEARSTATE_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_CLEARSTATE_DOTSOURCE = ''

    function script:F {
        param([string]$Rel, [int]$Age, [int]$Issue = 0)
        [pscustomobject]@{ RelativePath = $Rel; Name = (Split-Path $Rel -Leaf); AgeDays = $Age; IssueNum = $Issue }
    }
}

Describe 'Get-StateReapPlan (#574)' {
    It 'reaps an old briefing whose issue has no live session' {
        $p = Get-StateReapPlan -Files @((script:F 'briefing-123.txt' 30 123)) -LiveIssues @() -MaxAgeDays 14
        @($p.Reap).File | Should -Contain 'briefing-123.txt'
    }
    It 'a LIVE session protects its files at ANY age' {
        $p = Get-StateReapPlan -Files @((script:F 'briefing-123.txt' 300 123)) -LiveIssues @(123) -MaxAgeDays 14
        @($p.Reap).Count | Should -Be 0
        @($p.Keep)[0].Reason | Should -Match 'LIVE'
    }
    It 'young files stay whatever their shape' {
        $p = Get-StateReapPlan -Files @((script:F 'launch-99.ps1' 2 99)) -LiveIssues @() -MaxAgeDays 14
        @($p.Reap).Count | Should -Be 0
    }
    It 'durable records are NEVER reaped, at any age' {
        $files = @(
            (script:F 'sessions.json' 400), (script:F 'sessions-history.jsonl' 400),
            (script:F 'active-run.json' 400), (script:F 'expert.json' 400),
            (script:F 'denials.jsonl' 400), (script:F 'fleet/findings.json' 400),
            (script:F 'brake-armed.json' 400)
        )
        $p = Get-StateReapPlan -Files $files -LiveIssues @() -MaxAgeDays 14
        @($p.Reap).Count | Should -Be 0
    }
    It 'an UNRECOGNIZED file is somebody''s state - kept' {
        $p = Get-StateReapPlan -Files @((script:F 'something-new.json' 400)) -LiveIssues @() -MaxAgeDays 14
        @($p.Reap).Count | Should -Be 0
        @($p.Keep)[0].Reason | Should -Match 'never reaped'
    }
    It 'compaction snapshots and per-issue logs reap by age' {
        $files = @(
            (script:F 'compact-snapshots/2026-07-01.jsonl' 30),
            (script:F 'logs/issue-200.log' 30 200),
            (script:F 'signal-brake-200.posted' 30)
        )
        $p = Get-StateReapPlan -Files $files -LiveIssues @() -MaxAgeDays 14
        @($p.Reap).Count | Should -Be 3
    }
    It 'every reap entry carries a reviewable reason' {
        $p = Get-StateReapPlan -Files @((script:F 'expert-brief-50.md' 60 50)) -LiveIssues @() -MaxAgeDays 14
        @($p.Reap)[0].Reason | Should -Match '60d old'
    }
}

Describe 'Get-StateFileIssue (#574)' {
    It 'extracts the issue from each per-issue shape' {
        Get-StateFileIssue -Name 'briefing-123.txt' | Should -Be 123
        Get-StateFileIssue -Name 'launch-45.ps1' | Should -Be 45
        Get-StateFileIssue -Name 'expert-brief-7.md' | Should -Be 7
        Get-StateFileIssue -Name 'issue-88.log' -RelativePath 'logs/issue-88.log' | Should -Be 88
    }
    It 'returns 0 for non-per-issue files' {
        Get-StateFileIssue -Name 'sessions.json' | Should -Be 0
    }
}
