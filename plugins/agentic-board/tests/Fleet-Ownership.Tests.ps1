#Requires -Modules Pester
<#  Pester tests for Fleet-Ownership.ps1 - the fleet file-ownership guard (P3-3,
    "one owner per file"). Side-effecting (disk + git + process liveness), so it
    exposes a dot-source guard ($env:ABIOS_FLEETOWNERSHIP_DOTSOURCE) to unit-test the
    pure helpers (path normalization, overlap, conflict detection, dead-claim prune)
    with zero I/O, plus a disk round-trip via -Path injection. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Fleet-Ownership.ps1' | Resolve-Path
    $env:ABIOS_FLEETOWNERSHIP_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_FLEETOWNERSHIP_DOTSOURCE = ''
}

Describe 'ConvertTo-NormPath' {
    It 'converts backslashes to forward slashes' {
        ConvertTo-NormPath 'a\b\c.ps1' | Should -Be 'a/b/c.ps1'
    }
    It 'trims a leading ./ and a trailing slash' {
        ConvertTo-NormPath './a/b/' | Should -Be 'a/b'
    }
    It 'lowercases for case-insensitive comparison' {
        ConvertTo-NormPath 'Scripts/Foo.PS1' | Should -Be 'scripts/foo.ps1'
    }
}

Describe 'Test-PathOverlap' {
    It 'identical paths overlap' {
        Test-PathOverlap 'a/b.ps1' 'a/b.ps1' | Should -BeTrue
    }
    It 'different files under the same dir do NOT overlap' {
        Test-PathOverlap 'a/x.ps1' 'a/y.ps1' | Should -BeFalse
    }
    It 'a directory overlaps a file inside it (either order)' {
        Test-PathOverlap 'src' 'src/x.ps1' | Should -BeTrue
        Test-PathOverlap 'src/x.ps1' 'src' | Should -BeTrue
    }
    It 'is boundary-safe: a dir does not overlap a sibling with the same prefix' {
        Test-PathOverlap 'src' 'srcfoo/x.ps1' | Should -BeFalse
    }
    It 'is case-insensitive and slash-agnostic' {
        Test-PathOverlap 'A\B.ps1' 'a/b.ps1' | Should -BeTrue
    }
}

Describe 'New-Ownership' {
    It 'builds a claim with normalized paths and the given fields' {
        $c = New-Ownership -Issue 241 -Branch 'issue-241-x' -Paths 'Scripts\A.ps1','b/c' -SessionPid 123 -HostName 'PC1' -Now 't'
        $c.issue      | Should -Be 241
        $c.branch     | Should -Be 'issue-241-x'
        $c.paths      | Should -Be @('scripts/a.ps1','b/c')
        $c.sessionPid | Should -Be 123
        $c.host       | Should -Be 'PC1'
        $c.ts         | Should -Be 't'
    }
    It 'splits comma-joined paths (the pwsh -File case)' {
        (New-Ownership -Issue 1 -Paths 'a,b' -Now 't').paths | Should -Be @('a','b')
    }
}

Describe 'Find-OwnershipConflicts' {
    It 'reports no conflict against an empty registry' {
        @(Find-OwnershipConflicts @() (New-Ownership -Issue 1 -Paths 'a' -Now 't')).Count | Should -Be 0
    }
    It 'does NOT conflict with the same issue re-claiming its own paths' {
        $ex = @(New-Ownership -Issue 1 -Paths 'a/b.ps1' -Now 't')
        @(Find-OwnershipConflicts $ex (New-Ownership -Issue 1 -Paths 'a/b.ps1' -Now 't2')).Count | Should -Be 0
    }
    It 'reports a conflict when another issue owns an overlapping path' {
        $ex = @(New-Ownership -Issue 1 -Branch 'i1' -Paths 'src/shared.ps1' -Now 't')
        $r  = @(Find-OwnershipConflicts $ex (New-Ownership -Issue 2 -Paths 'src/shared.ps1' -Now 't'))
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 1
        $r[0].paths | Should -Be @('src/shared.ps1')
    }
    It 'does not conflict on disjoint paths' {
        $ex = @(New-Ownership -Issue 1 -Paths 'a/x.ps1' -Now 't')
        @(Find-OwnershipConflicts $ex (New-Ownership -Issue 2 -Paths 'a/y.ps1' -Now 't')).Count | Should -Be 0
    }
    It 'detects directory-vs-file overlap across issues' {
        $ex = @(New-Ownership -Issue 1 -Paths 'src' -Now 't')
        @(Find-OwnershipConflicts $ex (New-Ownership -Issue 2 -Paths 'src/deep/x.ps1' -Now 't')).Count | Should -Be 1
    }
}

Describe 'Remove-DeadClaims (injected liveness predicate)' {
    It 'keeps live-PID claims and drops dead ones' {
        $claims = @(
            (New-Ownership -Issue 1 -Paths 'a' -SessionPid 100 -Now 't'),
            (New-Ownership -Issue 2 -Paths 'b' -SessionPid 200 -Now 't')
        )
        $isAlive = { param($processId) $processId -eq 100 }   # only 100 is "alive"
        $r = @(Remove-DeadClaims $claims $isAlive)
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 1
    }
    It 'keeps claims with no pid (pid 0) rather than dropping them' {
        $claims = @(New-Ownership -Issue 1 -Paths 'a' -SessionPid 0 -Now 't')
        @(Remove-DeadClaims $claims { param($processId) $false }).Count | Should -Be 1
    }
}

Describe 'Read/Write/Release round-trip (disk, via -Path injection)' {
    BeforeAll {
        $script:Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-own-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $script:Tmp | Out-Null
        $script:File = Join-Path $script:Tmp 'ownership.json'
    }
    AfterAll { Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue }

    It 'reads an empty array when the file is missing' {
        @(Read-Ownership -Path $script:File).Count | Should -Be 0
    }
    It 'writes then reads back a claim' {
        Write-Ownership -Path $script:File -Claim (New-Ownership -Issue 7 -Paths 'a/b.ps1' -Now 't')
        $r = @(Read-Ownership -Path $script:File)
        $r.Count | Should -Be 1
        $r[0].issue | Should -Be 7
    }
    It 'upserts by issue (a re-claim replaces the paths, no duplicate row)' {
        Write-Ownership -Path $script:File -Claim (New-Ownership -Issue 7 -Paths 'a/b.ps1','c/d.ps1' -Now 't2')
        $r = @(Read-Ownership -Path $script:File | Where-Object { $_.issue -eq 7 })
        $r.Count | Should -Be 1
        @($r[0].paths) | Should -Be @('a/b.ps1','c/d.ps1')
    }
    It 'releases a claim by issue' {
        Remove-OwnershipClaim -Path $script:File -Issue 7
        @(Read-Ownership -Path $script:File | Where-Object { $_.issue -eq 7 }).Count | Should -Be 0
    }
    It 'returns an empty array on a corrupt file instead of throwing' {
        Set-Content -Path $script:File -Value '{ not json'
        @(Read-Ownership -Path $script:File).Count | Should -Be 0
    }
}
