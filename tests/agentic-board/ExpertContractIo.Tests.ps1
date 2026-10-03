#Requires -Modules Pester
<#  Tests for ExpertContractIo.ps1 — the /board expert contract (config writes it, auto reads it).

    Pure filesystem IO (no gh), guarded by $env:ABIOS_EXPERTCONTRACT_DOTSOURCE. These pin the
    default contract shape, the JSON round-trip, and the deep default-merge that lets a partial
    on-disk contract still resolve every key (so `auto` never hits a missing setting). #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'ExpertContractIo.ps1' | Resolve-Path
    $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = ''
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("expert-" + [guid]::NewGuid().ToString('N') + ".json")
}
AfterAll { if (Test-Path $script:Tmp) { Remove-Item $script:Tmp -Force } }

Describe 'New-ExpertContract (defaults)' {
    It 'has all top-level keys' {
        $c = New-ExpertContract
        foreach ($k in 'role','autonomy','dod','evidence','boardSelfDrive','budget','capabilities') {
            $c.ContainsKey($k) | Should -BeTrue -Because "key '$k' must exist"
        }
    }
    It 'brakes on the irreversible actions by default' {
        (New-ExpertContract).autonomy.irreversible | Should -Contain 'merge'
        (New-ExpertContract).autonomy.irreversible | Should -Contain 'delete'
    }
    It 'enables all three evidence destinations by default' {
        $e = (New-ExpertContract).evidence
        $e.pr | Should -BeTrue; $e.issueComment | Should -BeTrue; $e.file | Should -BeTrue
    }
    It 'defaults board self-drive on with a cap and a discovered label' {
        $b = (New-ExpertContract).boardSelfDrive
        $b.createIssues | Should -BeTrue
        $b.label | Should -Be 'discovered'
        $b.cap | Should -BeGreaterThan 0
    }
    It 'defaults the codex-rescue review path to OFF (#646) - opt-in, never silent' {
        (New-ExpertContract).review.preferCodexRescue | Should -BeFalse
    }
}

Describe 'Write/Read round-trip' {
    It 'writes then reads back an equal contract' {
        $c = New-ExpertContract
        $c.role = 'Expert in Power BI visuals'
        $c.budget.maxMinutes = 45
        Write-ExpertContract -Contract $c -Path $script:Tmp
        Test-Path $script:Tmp | Should -BeTrue
        $r = Read-ExpertContract -Path $script:Tmp
        $r.role | Should -Be 'Expert in Power BI visuals'
        $r.budget.maxMinutes | Should -Be 45
    }
}

Describe 'Read-ExpertContract default-merge' {
    It 'fills missing keys from defaults when the file is partial' {
        '{ "role": "partial only" }' | Set-Content -Path $script:Tmp -Encoding utf8
        $r = Read-ExpertContract -Path $script:Tmp
        $r.role | Should -Be 'partial only'
        $r.evidence.pr | Should -BeTrue          # filled from defaults
        $r.autonomy.irreversible | Should -Contain 'merge'
        $r.review.preferCodexRescue | Should -BeFalse   # (#646) a contract older than this key still resolves off, not missing
    }
    It 'preserves an explicit opt-in written by an older or hand-edited contract (#646)' {
        '{ "review": { "preferCodexRescue": true } }' | Set-Content -Path $script:Tmp -Encoding utf8
        (Read-ExpertContract -Path $script:Tmp).review.preferCodexRescue | Should -BeTrue
    }
    It 'returns full defaults when the file does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("nope-" + [guid]::NewGuid().ToString('N') + ".json")
        $r = Read-ExpertContract -Path $missing
        $r.evidence.file | Should -BeTrue
        $r.budget.maxIterations | Should -BeGreaterThan 0
    }
}
