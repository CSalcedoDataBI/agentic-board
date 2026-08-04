#Requires -Modules Pester
<#  Lint: no NEW raw `gh` call sites outside Invoke-Gh.ps1 (#571).

    Invoke-Gh.ps1 exists because bare gh turns a 401 into an empty result (#303/#86) - and yet
    95 raw sites still bypassed it when the architecture review counted (2026-08-03), including
    the exact anti-pattern quoted in the wrapper's own header. Migrating all of them at once is
    churn; letting NEW ones appear is regression. This lint freezes the baseline: every file's
    raw-call count may only go DOWN. Migrate a call, lower the number here; add a raw call, this
    test names the file and fails.

    The scan is a heuristic (a regex over non-comment lines), so the baseline is per-file counts
    rather than exact locations - good enough to catch drift without false-failing on refactors
    that merely move lines within a file. #>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path
    $script:RawGhPattern = '(^|[\s;({=|])(&\s*)?gh(\.exe)?\s+(api|pr|issue|project|repo|release|search|label|auth|workflow)\b'

    function script:Get-RawGhCount {
        param([string]$Path)
        $n = 0
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            $t = $line.Trim()
            if ($t.StartsWith('#')) { continue }
            if ($t -match $script:RawGhPattern) { $n++ }
        }
        $n
    }

    # The frozen baseline (2026-08-04, after migrating Board-Work's worst offenders in #571).
    # A file not listed here has ZERO tolerated raw calls.
    $script:Baseline = @{
        'Board-Work.ps1'            = 10
        'Apply-FieldPreset.ps1'     = 6
        'Board-Plan.ps1'            = 6
        'Board-ReviewGate.ps1'      = 5
        'Expert-Auto.ps1'           = 4
        'Board-Merge.ps1'           = 3
        'Board-Breakdown.ps1'       = 3
        'New-BoardPR.ps1'           = 3
        'Set-BoardField.ps1'        = 3
        'Board-Doctor.ps1'          = 2
        'Expert-RunVerify.ps1'      = 2
        'Fleet-Handoff.ps1'         = 2
        'Publish-DocsWiki.ps1'      = 2
        'Apply-LabelPreset.ps1'     = 1
        'Brake-Guard.ps1'           = 1
        'Resolve-SkillOwner.ps1'    = 1
        'Fleet-Plan.ps1'            = 1
        'Fleet-Supervisor.ps1'      = 1
        'Get-ToolkitFreshness.ps1'  = 1
        'Install-RepoTemplates.ps1' = 1
        'Board-Handoff.ps1'         = 1
    }
}

Describe 'Raw gh lint - the wrapper is the only door that gets wider (#571)' {
    It 'no script exceeds its frozen raw-gh baseline (new raw calls are a regression)' {
        $violations = @()
        foreach ($f in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter *.ps1 |
                 Where-Object { $_.Name -ne 'Invoke-Gh.ps1' }) {
            $count = script:Get-RawGhCount -Path $f.FullName
            $allowed = if ($script:Baseline.ContainsKey($f.Name)) { $script:Baseline[$f.Name] } else { 0 }
            if ($count -gt $allowed) {
                $violations += "{0}: {1} raw gh call(s), baseline {2} - route new calls through Invoke-Gh (#303: bare gh turns a 401 into an empty result)" -f $f.Name, $count, $allowed
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'the baseline itself only shrinks: no listed file is already clean (else drop its entry)' {
        # A baseline entry for a file with zero raw calls is a stale allowance a future raw
        # call could hide under. Keeping the list honest is part of the lint.
        $stale = @()
        foreach ($name in $script:Baseline.Keys) {
            $path = Join-Path $script:ScriptsDir $name
            if (-not (Test-Path -LiteralPath $path)) { $stale += "$name (file gone)"; continue }
            if ((script:Get-RawGhCount -Path $path) -eq 0) { $stale += "$name (already clean)" }
        }
        $stale | Should -BeNullOrEmpty
    }
}
