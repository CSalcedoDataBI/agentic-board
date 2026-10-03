#Requires -Modules Pester
<#  Error-boundary tests — exit 1 with no message and raw exceptions (#485).

    Field sweep (#476): 945 sessions, 295 failed invocations. Two failure shapes
    account for 128 of the 172 unclassified failures:

      85  exit 1 with no message   — throw goes to stderr only; caller sees nothing.
      43  raw PowerShell exception — file path + CategoryInfo reaches the user.

    Fix: each of the six worst-offending scripts now has a top-level `trap` block
    that intercepts every unhandled terminating error and writes a clean one-line
    "ERROR: <message>" to stdout before exiting 1.

    These tests verify the contract from the outside (no dot-source, no mocks):
      1. A failure path exits 1 — not 0.
      2. The output contains "ERROR:" on stdout — not silent.
      3. The output does NOT contain raw PowerShell exception markers
         (CategoryInfo, FullyQualifiedErrorId) — not a raw stack dump.

    The "missing token" path is the cheapest forcing function: it fires before any
    gh call and throws at the very first line of the main body. Passing a var name
    that is guaranteed absent guarantees the throw every time.

    Tests run the scripts with *>&1 (all streams merged) to capture everything the
    child process writes. The trap fires in the child's scope and writes "ERROR: …"
    to stream 1/6 (stdout/Information), which IS captured. Without the trap the
    throw would go to stream 2 (ErrorRecord), which is also captured but in the raw
    PS exception format (CategoryInfo, FullyQualifiedErrorId, file:line). #>

BeforeAll {
    $script:Dir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path

    # A var name guaranteed absent from the Windows USER environment.
    $script:AbsentVar = 'ABIOS_ERROR_BOUNDARY_TEST_485'
    [System.Environment]::SetEnvironmentVariable($script:AbsentVar, $null, 'User')

    # Markers that appear in raw PowerShell exception output, never in our clean messages.
    $script:RawPatterns = @(
        '(?m)^\s*\+ CategoryInfo\s*:',
        '(?m)^\s*\+ FullyQualifiedErrorId\s*:',
        'At .*\.ps1:\d'
    )

    function script:Assert-CleanError {
        param([string]$Out, [int]$Code, [string]$Script)
        $Code | Should -Be 1 -Because "$Script must exit 1 on a forced error"
        $Out  | Should -Match 'ERROR:' -Because "$Script must print a reason on stdout"
        foreach ($pat in $script:RawPatterns) {
            $Out | Should -Not -Match $pat -Because "$Script must not leak a raw PS exception"
        }
    }

    # Store and clear GH_TOKEN for the duration of the suite; restore in AfterAll.
    $script:PrevGH = $env:GH_TOKEN
    $env:GH_TOKEN = ''
}

AfterAll {
    if ($script:PrevGH) { $env:GH_TOKEN = $script:PrevGH }
    else { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
}

# ── Board-Fill.ps1 ────────────────────────────────────────────────────────────
Describe 'Board-Fill.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'Board-Fill.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -TokenVar $script:AbsentVar *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'Board-Fill.ps1'
    }
}

# ── Board-Work.ps1 ───────────────────────────────────────────────────────────
Describe 'Board-Work.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'Board-Work.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -TokenVar $script:AbsentVar -ProjectNum 13 *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'Board-Work.ps1'
    }
}

# ── New-BoardPR.ps1 ───────────────────────────────────────────────────────────
Describe 'New-BoardPR.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'New-BoardPR.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -Issue 1 -TokenVar $script:AbsentVar *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'New-BoardPR.ps1'
    }
}

# ── Board-Merge.ps1 ───────────────────────────────────────────────────────────
Describe 'Board-Merge.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'Board-Merge.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -PR 1 -TokenVar $script:AbsentVar *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'Board-Merge.ps1'
    }
}

# ── Board-Triage.ps1 ──────────────────────────────────────────────────────────
Describe 'Board-Triage.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'Board-Triage.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -TokenVar $script:AbsentVar *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'Board-Triage.ps1'
    }
}

# ── Board-Breakdown.ps1 ───────────────────────────────────────────────────────
Describe 'Board-Breakdown.ps1 error boundary (#485)' {
    BeforeAll { $script:S = Join-Path $script:Dir 'Board-Breakdown.ps1' }

    It 'exits 1 with a clean ERROR message when the token var is missing — never silent' {
        $out  = & $script:S -Parent 1 -Tasks 'Task A' -TokenVar $script:AbsentVar *>&1 | Out-String
        $code = $LASTEXITCODE
        script:Assert-CleanError -Out $out -Code $code -Script 'Board-Breakdown.ps1'
    }
}
