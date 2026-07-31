#Requires -Modules Pester
<#  Tests for Expert-EndToEnd.ps1 — may an autonomous run close its own work? (#530, part of #526)

    Four conditions, each covering a failure the others cannot see. The tests that matter are the
    ones proving a SINGLE missing condition is enough to refuse — the whole point is that this
    cannot collapse into one flag. #>

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Expert-EndToEnd.ps1' | Resolve-Path
    $env:ABIOS_ENDTOEND_DOTSOURCE = '1'
    . $script:Script
    $env:ABIOS_ENDTOEND_DOTSOURCE = ''

    # The all-green baseline; each test knocks out exactly one condition.
    function script:Allowed {
        param([hashtable]$Override = @{})
        $a = @{ Ordered = $true; WorkClass = 'code'; ReviewedHead = $true; TestsRecorded = $true }
        foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
        return (Test-EndToEndAllowed @a)
    }
}

Describe 'Test-EndToEndAllowed — all four conditions met' {
    It 'allows the close' { (script:Allowed).allowed | Should -BeTrue }
    It 'has nothing missing' { (script:Allowed).missing.Count | Should -Be 0 }
    It 'says why it was allowed' { (script:Allowed).reason | Should -Match 'revisado y probado' }
}

Describe 'Test-EndToEndAllowed — any single missing condition refuses' {
    It 'refuses without the explicit order — a stored setting is not an instruction' {
        $v = script:Allowed @{ Ordered = $false }
        $v.allowed | Should -BeFalse
        $v.reason  | Should -Match 'orden explicita'
    }
    It 'refuses a VISUAL change even when ordered, reviewed and tested' {
        # The owner said this one plainly: what he judges by looking at it stays his, whatever else
        # is green and whatever he told the run to do.
        $v = script:Allowed @{ WorkClass = 'visual' }
        $v.allowed | Should -BeFalse
        $v.reason  | Should -Match 'se juzga mirandolo'
    }
    It 'refuses an UNKNOWN class — not knowing what changed is not permission' {
        $v = script:Allowed @{ WorkClass = 'unknown' }
        $v.allowed | Should -BeFalse
        $v.reason  | Should -Match 'no se pudo determinar'
    }
    It 'refuses without a real review of THIS commit' {
        $v = script:Allowed @{ ReviewedHead = $false }
        $v.allowed | Should -BeFalse
        $v.reason  | Should -Match 'revision real de ESTE commit'
    }
    It 'refuses when testable work went untested' {
        $v = script:Allowed @{ TestsRecorded = $false }
        $v.allowed | Should -BeFalse
        $v.reason  | Should -Match 'pruebas automaticas'
    }
}

Describe 'Test-EndToEndAllowed — every unmet condition is named, not just the first' {
    # Reporting one reason at a time forces a round trip per condition, which misrepresents how far
    # the work actually is.
    It 'lists all four when nothing is met' {
        $v = Test-EndToEndAllowed -Ordered $false -WorkClass 'visual' -ReviewedHead $false -TestsRecorded $false
        $v.missing.Count | Should -Be 4
    }
    It 'lists exactly the two that are missing' {
        $v = script:Allowed @{ ReviewedHead = $false; TestsRecorded = $false }
        $v.missing.Count | Should -Be 2
        ($v.missing -join ' ') | Should -Match 'revision real'
        ($v.missing -join ' ') | Should -Match 'pruebas automaticas'
    }
}

Describe 'Test-EndToEndAllowed — the tests requirement comes from the contract, not the run' {
    # A per-run "no se podia probar" is a self-issued excuse. A project with genuinely no automated
    # tests says so once, in writing, in its contract (dod.tests).
    It 'skips the test condition when the contract says this project has no automated tests' {
        $v = script:Allowed @{ TestsRecorded = $false; TestsRequired = $false }
        $v.allowed | Should -BeTrue
    }
    It 'still refuses a visual change even with the test condition switched off' {
        $v = script:Allowed @{ TestsRecorded = $false; TestsRequired = $false; WorkClass = 'visual' }
        $v.allowed | Should -BeFalse
    }
    It 'requires tests by default' {
        (Test-EndToEndAllowed -Ordered $true -WorkClass 'code' -ReviewedHead $true -TestsRecorded $false).allowed |
            Should -BeFalse
    }
}

Describe 'Test-EndToEndAllowed — defaults refuse' {
    It 'refuses with nothing supplied but the class' {
        (Test-EndToEndAllowed -WorkClass 'code').allowed | Should -BeFalse
    }
    It 'refuses on an empty class' {
        (Test-EndToEndAllowed -Ordered $true -WorkClass '' -ReviewedHead $true -TestsRecorded $true).allowed |
            Should -BeFalse
    }
}

Describe 'Test-EndToEndAllowed — a project can widen what stays with the human' {
    It 'honours a policy that reserves code for the human too' {
        $strict = @{ visualPatterns = @('*.png'); humanApproves = @('visual','code') }
        (script:Allowed @{ WorkClassPolicy = $strict }).allowed | Should -BeFalse
    }
}

Describe 'Format-EndToEndVerdict' {
    It 'states the permission plainly when allowed' {
        Format-EndToEndVerdict -Verdict (script:Allowed) | Should -Match 'permitido'
    }
    It 'lists each missing condition on its own line' {
        $t = Format-EndToEndVerdict -Verdict (script:Allowed @{ ReviewedHead = $false; TestsRecorded = $false })
        @($t -split "`n" | Where-Object { $_ -match '^\s+- ' }).Count | Should -Be 2
    }
    It 'says what to do instead of just refusing' {
        Format-EndToEndVerdict -Verdict (script:Allowed @{ Ordered = $false }) |
            Should -Match 'el cierre lo hace una persona'
    }
}

Describe 'Test-CiChecksPassed — CI evidence, read from the checks themselves (#536)' {
    # Extracted from Board-Merge so the one condition that decides a merge can be tested without a
    # network round-trip. The defect that motivated it was NOT in this logic but in its INPUT:
    # `gh pr checks $PR` was called with $PR already clobbered to 0 by a dot-source, so the answer
    # was always "no checks" and the tests condition could never be met. See Board-Merge.Tests.ps1.

    It 'accepts a PR whose checks all passed' {
        Test-CiChecksPassed -ChecksJson '[{"bucket":"pass","name":"Pester"},{"bucket":"pass","name":"sync"}]' |
            Should -BeTrue
    }
    It 'accepts passing checks alongside skipped ones' {
        Test-CiChecksPassed -ChecksJson '[{"bucket":"pass","name":"Pester"},{"bucket":"skipping","name":"docs"}]' |
            Should -BeTrue
    }
    It 'refuses when nothing actually PASSED, only skipped' {
        # A PR whose single check was SKIPPED had no CI run on that commit at all.
        Test-CiChecksPassed -ChecksJson '[{"bucket":"skipping","name":"docs"}]' | Should -BeFalse
    }
    It 'refuses a failing check' {
        Test-CiChecksPassed -ChecksJson '[{"bucket":"pass","name":"Pester"},{"bucket":"fail","name":"review"}]' |
            Should -BeFalse
    }
    It 'refuses a cancelled check' {
        Test-CiChecksPassed -ChecksJson '[{"bucket":"pass","name":"Pester"},{"bucket":"cancel","name":"sync"}]' |
            Should -BeFalse
    }
    It 'refuses a pending check — green means finished, not started' {
        Test-CiChecksPassed -ChecksJson '[{"bucket":"pass","name":"Pester"},{"bucket":"pending","name":"sync"}]' |
            Should -BeFalse
    }
    It 'refuses when the query returned nothing at all' {
        # THE regression that made end-to-end inert: `gh pr checks 0` exits 1 with empty stdout.
        # "I could not read the checks" must never read as "the checks passed".
        Test-CiChecksPassed -ChecksJson ''   | Should -BeFalse
        Test-CiChecksPassed -ChecksJson '[]' | Should -BeFalse
    }
    It 'refuses unparseable output rather than assuming the best' {
        Test-CiChecksPassed -ChecksJson 'not json at all' | Should -BeFalse
    }
}

Describe 'Test-EndToEndAllowed — the tests requirement comes from the CONTRACT (#536)' {
    It 'does not demand tests from a project whose contract declares none' {
        $v = Test-EndToEndAllowed -Ordered $true -WorkClass 'code' -ReviewedHead $true `
                                  -TestsRecorded $false -TestsRequired $false
        $v.allowed | Should -BeTrue
    }
    It 'still demands them when the contract asks for them' {
        $v = Test-EndToEndAllowed -Ordered $true -WorkClass 'code' -ReviewedHead $true `
                                  -TestsRecorded $false -TestsRequired $true
        $v.allowed | Should -BeFalse
    }
}
