#Requires -Modules Pester
<#  Pester tests for Fleet-Supervisor.ps1 - stall detection + fleet termination (P3-5).
    Watches the live fleet and decides: which sessions have stalled (running too long with
    no PR), whether the whole run is complete, and whether it should STOP (guard against
    runaway loops). Pure verdict core behind a dot-source guard
    ($env:ABIOS_FLEETSUPERVISOR_DOTSOURCE); only the CLI reads sessions.json / gh. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Supervisor.ps1' | Resolve-Path
    $env:ABIOS_FLEETSUPERVISOR_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FLEETSUPERVISOR_DOTSOURCE = ''

    function New-Sess {
        param([int]$Issue, [int]$AgeMin = 0, [string]$Pr = '', [bool]$Merged = $false)
        [pscustomobject]@{ issue = $Issue; ageMin = $AgeMin; pr = $Pr; merged = $Merged }
    }
}

Describe 'Test-SessionStalled' {
    It 'is not stalled while young' {
        Test-SessionStalled (New-Sess 1 -AgeMin 5) 30 | Should -BeFalse
    }
    It 'is stalled when old and still has no PR' {
        Test-SessionStalled (New-Sess 1 -AgeMin 60) 30 | Should -BeTrue
    }
    It 'is NOT stalled when old but a PR is already open (that is progress)' {
        Test-SessionStalled (New-Sess 1 -AgeMin 60 -Pr 'http://pr/1') 30 | Should -BeFalse
    }
}

Describe 'Get-StalledSessions' {
    It 'returns only the stalled sessions' {
        $s = @( (New-Sess 1 -AgeMin 5), (New-Sess 2 -AgeMin 90), (New-Sess 3 -AgeMin 90 -Pr 'p') )
        $r = @(Get-StalledSessions $s 30)
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 2
    }
}

Describe 'Test-FleetComplete' {
    It 'is complete when every session is merged' {
        Test-FleetComplete @( (New-Sess 1 -Merged $true), (New-Sess 2 -Merged $true) ) | Should -BeTrue
    }
    It 'is not complete while any session is unmerged' {
        Test-FleetComplete @( (New-Sess 1 -Merged $true), (New-Sess 2) ) | Should -BeFalse
    }
    It 'treats an empty fleet as complete' {
        Test-FleetComplete @() | Should -BeTrue
    }
}

Describe 'Get-FleetVerdict (termination policy)' {
    It 'says STOP + complete when all sessions merged' {
        $v = Get-FleetVerdict @( (New-Sess 1 -Merged $true) ) 30 2
        $v.complete   | Should -BeTrue
        $v.shouldStop | Should -BeTrue
        $v.reason     | Should -Match 'complet'
    }
    It 'says STOP when stalled count reaches the max' {
        $v = Get-FleetVerdict @( (New-Sess 1 -AgeMin 90), (New-Sess 2 -AgeMin 90) ) 30 2
        $v.shouldStop | Should -BeTrue
        $v.reason     | Should -Match 'stall'
        @($v.stalled).Count | Should -Be 2
    }
    It 'keeps going when work is in progress and nothing is stalled' {
        $v = Get-FleetVerdict @( (New-Sess 1 -AgeMin 5 -Pr 'p'), (New-Sess 2 -AgeMin 5) ) 30 2
        $v.complete   | Should -BeFalse
        $v.shouldStop | Should -BeFalse
    }
}

Describe 'New-StallCommentBody - the stall signal the human actually sees (#565)' {
    It 'names the issue, the age, the threshold, the log and the takeover command' {
        $b = New-StallCommentBody -Issue 42 -AgeMin 45 -ThresholdMin 30
        $b | Should -Match '\[abios-stall\] issue=42'
        $b | Should -Match '45 minutes with no PR'
        $b | Should -Match '30 min'
        $b | Should -Match 'issue-42\.log'
        $b | Should -Match '-Start 42 -TakeOver'
    }
}

Describe 'Get-StallMarkerName - dedup per SESSION, not per issue number (#565 review)' {
    It 'keys on repo + issue + start time' {
        $s = [pscustomobject]@{ repo = 'owner/name'; issue = 42; started = '2026-08-03 10:00' }
        Get-StallMarkerName -Session $s | Should -Be 'signal-stall-owner-name-42-2026-08-03-10-00.posted'
    }
    It 'a relaunch (new started) gets a NEW marker - its stall is not suppressed by the old ghost' {
        $a = [pscustomobject]@{ repo = 'o/r'; issue = 7; started = '2026-08-03 10:00' }
        $b = [pscustomobject]@{ repo = 'o/r'; issue = 7; started = '2026-08-03 14:30' }
        (Get-StallMarkerName -Session $a) | Should -Not -Be (Get-StallMarkerName -Session $b)
    }
    It 'the same issue number in another repo gets a different marker' {
        $a = [pscustomobject]@{ repo = 'o/r1'; issue = 7; started = 'x' }
        $b = [pscustomobject]@{ repo = 'o/r2'; issue = 7; started = 'x' }
        (Get-StallMarkerName -Session $a) | Should -Not -Be (Get-StallMarkerName -Session $b)
    }
}

Describe 'Stall posting requires an ESTABLISHED no-PR fact (#565 round 4)' {
    It 'a session whose PR lookup failed (prKnown=false) is skipped by the publisher' {
        # Publish-StallSignals must skip it BEFORE any gh call; we prove the skip by the absence
        # of a dedup marker after the call (a posted signal writes one).
        $env:ABIOS_STATE_DIR_TEST = $TestDrive
        $s = [pscustomobject]@{ issue = 42; repo = 'o/r'; started = 'x'; ageMin = 99; prKnown = $false }
        { Publish-StallSignals -Stalled @($s) -ThresholdMin 30 } | Should -Not -Throw
        @(Get-ChildItem $TestDrive -Filter 'signal-stall-*').Count | Should -Be 0
        $env:ABIOS_STATE_DIR_TEST = $null
    }
}
