#Requires -Modules Pester
<#  Pester tests for Fleet-Findings.ps1 - the fleet shared-findings blackboard (P3-1).

    Fleet-Findings.ps1 is a side-effecting command (disk + git + Write-Host), so it
    exposes a dot-source guard: with $env:ABIOS_FLEETFINDINGS_DOTSOURCE set it returns
    after defining every function WITHOUT reading args or touching disk/git. That lets
    us unit-test the pure helpers (Split-CsvArg / New-FleetFinding / Merge-FleetFinding
    / Select-FleetFindings) with zero side effects, and the disk round-trip against a
    temp file via the -Path injection on Read-FleetFindings / Write-FleetFinding. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Findings.ps1' | Resolve-Path
    $env:ABIOS_FLEETFINDINGS_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FLEETFINDINGS_DOTSOURCE = ''
}

Describe 'Split-CsvArg (pwsh -File comma-joined arrays)' {
    It 'splits a single comma-joined string' {
        (Split-CsvArg 'a.ps1,b.ps1') | Should -Be @('a.ps1','b.ps1')
    }
    It 'trims whitespace around tokens' {
        (Split-CsvArg 'a, b ,c') | Should -Be @('a','b','c')
    }
    It 'de-duplicates while preserving order' {
        (Split-CsvArg 'a,b,a,c') | Should -Be @('a','b','c')
    }
    It 'drops empty tokens' {
        (Split-CsvArg 'a,,b,') | Should -Be @('a','b')
    }
    It 'returns an empty array for empty input' {
        @(Split-CsvArg @()).Count | Should -Be 0
    }
    It 'splits inside a native multi-element array too' {
        (Split-CsvArg @('a','b,c')) | Should -Be @('a','b','c')
    }
}

Describe 'New-FleetFinding' {
    It 'builds a record with all given fields and a fixed timestamp' {
        $f = New-FleetFinding -Issue 239 -Repo 'o/r' -Branch 'issue-239-x' -Files 'a.ps1' `
                 -Decisions 'used JSON' -Gotchas 'watch pagination' -Labels 'fleet' `
                 -Pr 'http://pr/1' -Status 'done' -HostName 'PC1' -Now '2026-07-10 12:00'
        $f.issue        | Should -Be 239
        $f.repo         | Should -Be 'o/r'
        $f.branch       | Should -Be 'issue-239-x'
        $f.filesTouched | Should -Be @('a.ps1')
        $f.decisions    | Should -Be @('used JSON')
        $f.gotchas      | Should -Be @('watch pagination')
        $f.labels       | Should -Be @('fleet')
        $f.pr           | Should -Be 'http://pr/1'
        $f.status       | Should -Be 'done'
        $f.host         | Should -Be 'PC1'
        $f.ts           | Should -Be '2026-07-10 12:00'
    }
    It 'defaults status to in-progress' {
        (New-FleetFinding -Issue 1 -Now 't').status | Should -Be 'in-progress'
    }
    It 'normalizes comma-joined files and labels into arrays' {
        $f = New-FleetFinding -Issue 1 -Files 'a,b' -Labels 'x,y' -Now 't'
        $f.filesTouched | Should -Be @('a','b')
        $f.labels       | Should -Be @('x','y')
    }
}

Describe 'Merge-FleetFinding (upsert by issue)' {
    It 'appends a finding for a new issue' {
        $a = @(New-FleetFinding -Issue 1 -Now 't')
        $r = @(Merge-FleetFinding $a (New-FleetFinding -Issue 2 -Now 't'))
        $r.Count | Should -Be 2
        $r[1].issue | Should -Be 2
    }
    It 'unions and de-duplicates array fields for an existing issue' {
        $a = @(New-FleetFinding -Issue 1 -Files 'a' -Decisions 'd1' -Now 't')
        $r = @(Merge-FleetFinding $a (New-FleetFinding -Issue 1 -Files @('a','b') -Decisions 'd2' -Now 't2'))
        $r.Count | Should -Be 1
        $r[0].filesTouched | Should -Be @('a','b')
        $r[0].decisions    | Should -Be @('d1','d2')
    }
    It 'updates scalar fields (status, pr, ts) when the new value is provided' {
        $a = @(New-FleetFinding -Issue 1 -Status 'in-progress' -Now 't1')
        $r = @(Merge-FleetFinding $a (New-FleetFinding -Issue 1 -Status 'done' -Pr 'http://pr/1' -Now 't2'))
        $r[0].status | Should -Be 'done'
        $r[0].pr     | Should -Be 'http://pr/1'
        $r[0].ts     | Should -Be 't2'
    }
    It 'keeps the existing scalar when the new value is empty' {
        $a = @(New-FleetFinding -Issue 1 -Repo 'o/r' -Now 't1')
        $r = @(Merge-FleetFinding $a (New-FleetFinding -Issue 1 -Now 't2'))
        $r[0].repo | Should -Be 'o/r'
    }
    It 'preserves the position of the upserted entry' {
        $a = @( (New-FleetFinding -Issue 1 -Now 't'), (New-FleetFinding -Issue 2 -Now 't') )
        $r = @(Merge-FleetFinding $a (New-FleetFinding -Issue 1 -Decisions 'new' -Now 't2'))
        $r[0].issue | Should -Be 1
        $r[1].issue | Should -Be 2
        $r[0].decisions | Should -Be @('new')
    }
}

Describe 'Select-FleetFindings (retrieval)' {
    BeforeAll {
        $script:All = @(
            (New-FleetFinding -Issue 1 -Files 'auth.ps1' -Decisions 'used MSAL' -Labels 'auth' -Now 't'),
            (New-FleetFinding -Issue 2 -Files 'board.ps1' -Gotchas 'pagination caps at 100' -Labels 'fleet' -Now 't')
        )
    }
    It 'returns everything when no filter is given' {
        @(Select-FleetFindings $All).Count | Should -Be 2
    }
    It 'filters by issue number' {
        $r = @(Select-FleetFindings $All -Issue 2)
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 2
    }
    It 'filters by label, case-insensitive' {
        $r = @(Select-FleetFindings $All -Label 'AUTH')
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 1
    }
    It 'filters by free text across decisions, gotchas and files (case-insensitive)' {
        (@(Select-FleetFindings $All -Text 'pagination')[0]).issue | Should -Be 2
        (@(Select-FleetFindings $All -Text 'msal')[0]).issue       | Should -Be 1
        (@(Select-FleetFindings $All -Text 'board.ps1')[0]).issue  | Should -Be 2
    }
    It 'ANDs multiple filters' {
        @(Select-FleetFindings $All -Issue 1 -Label 'fleet').Count | Should -Be 0
    }
}

Describe 'Read/Write round-trip (disk, via -Path injection)' {
    BeforeAll {
        $script:Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-find-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $script:Tmp | Out-Null
        $script:File = Join-Path $script:Tmp 'findings.json'
    }
    AfterAll { Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue }

    It 'reads an empty array when the file does not exist' {
        @(Read-FleetFindings -Path $script:File).Count | Should -Be 0
    }
    It 'writes then reads back a finding' {
        Write-FleetFinding -Path $script:File -Finding (New-FleetFinding -Issue 7 -Decisions 'x' -Now 't')
        $r = @(Read-FleetFindings -Path $script:File)
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 7
    }
    It 'upserts on a second write for the same issue (no duplicate, arrays union)' {
        Write-FleetFinding -Path $script:File -Finding (New-FleetFinding -Issue 7 -Decisions 'y' -Now 't2')
        $r = @(Read-FleetFindings -Path $script:File | Where-Object { $_.issue -eq 7 })
        $r.Count | Should -Be 1
        @($r[0].decisions) | Should -Be @('x','y')
    }
    It 'returns an empty array on a corrupt file instead of throwing' {
        Set-Content -Path $script:File -Value '{ this is not valid json'
        @(Read-FleetFindings -Path $script:File).Count | Should -Be 0
    }
}
