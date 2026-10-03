#Requires -Modules Pester
<#  Repo-wide syntax check: every plugin script must PARSE (#282).

    Motivation, from #274 / PR #280: the string "limite de $PrLimit:" parsed as a scope-qualified
    variable reference ($PrLimit: is `scope PrLimit`, not `$PrLimit` followed by a colon) and broke
    EVERY run of Board-Doctor.ps1. Nothing caught it but executing the script - it reads fine, it
    would have passed code review, and it sat on a code path the suite never exercised.

    So this is the cheapest total coverage available: PowerShell parses a whole file before running
    a single line of it, which means a pure AST parse proves the syntax of code the tests never
    call - the -Fix branches, the error handlers, the rarely-hit switches. It needs no network, no
    token and no gh, and it cannot produce a false positive: a parse error is always a real bug.

    Board-Doctor.Tests.ps1 used to carry a single-file version of this; it lives here now, for all
    of them. #>

BeforeDiscovery {
    # Discovery-time on purpose: it gives one `It` per script, so a failure names the file in the
    # test name instead of hiding inside one aggregate assertion.
    $script:ScriptRoot = Join-Path $PSScriptRoot '..' | Resolve-Path
    $script:ScriptFiles = @(
        Get-ChildItem -Path (Join-Path $script:ScriptRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $script:ScriptRoot 'hooks')   -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    ) | Sort-Object FullName
}

Describe 'Every plugin script' {
    # The count is passed in via -ForEach because it must be read at DISCOVERY time: an `It` body
    # runs in a different scope, where $script:ScriptFiles is not the variable set above.
    It 'is discovered by this test, so a broken glob cannot make the suite pass vacuously' -ForEach @{
        Found = @($script:ScriptFiles).Count
    } {
        # Fails closed: if the layout moves and the search finds nothing, that must be a red test,
        # never a silently empty pass (Pester generates zero per-file tests and says nothing). The
        # floor is deliberately loose - it only has to prove the search still resolves the real
        # scripts directory, not to be updated every time a script is added.
        $Found | Should -BeGreaterThan 20
    }

    It 'has no syntax errors in <_.Name>' -ForEach $script:ScriptFiles {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs) | Out-Null
        # Report line and message, not just a count: a bare "expected 0, got 3" sends the reader
        # back to the file to find out what broke.
        $detail = @($errs) | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }
        $detail -join "`n" | Should -BeNullOrEmpty
    }
}
