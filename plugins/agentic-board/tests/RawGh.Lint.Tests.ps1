#Requires -Modules Pester
<#  Lint: no NEW raw `gh` call sites outside Invoke-Gh.ps1 (#571).

    Invoke-Gh.ps1 exists because bare gh turns a 401 into an empty result (#303/#86) - and yet
    95 raw sites still bypassed it when the architecture review counted (2026-08-03), including
    the exact anti-pattern quoted in the wrapper's own header. Migrating all of them at once is
    churn; letting NEW ones appear is regression. This lint freezes the baseline: every file's
    raw-call count may only go DOWN. Migrate a call, lower the number here; add a raw call, this
    test names the file and fails.

    The scan walks the PowerShell AST and counts real CommandAst invocations of `gh` (round 3 of
    external review: a regex over lines counted user-facing STRINGS like "usa: gh issue reopen"
    as call sites, and every phantom allowance was headroom a real new call could hide under). #>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' 'scripts' | Resolve-Path

    function script:Get-RawGhCount {
        param([string]$Path)
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        @($cmds | Where-Object { $_.GetCommandName() -eq 'gh' }).Count
    }

    # The frozen baseline (2026-08-04, AST counts, after migrating Board-Work's worst offenders
    # in #571). A file not listed here has ZERO tolerated raw calls.
    $script:Baseline = @{
        'Board-Work.ps1'            = 8
        'Apply-FieldPreset.ps1'     = 6
        'Board-Plan.ps1'            = 6
        'Board-ReviewGate.ps1'      = 5
        'Board-Merge.ps1'           = 5
        'New-BoardPR.ps1'           = 4
        'Expert-Auto.ps1'           = 4
        'Board-Breakdown.ps1'       = 3
        'Set-BoardField.ps1'        = 3
        'Board-Doctor.ps1'          = 2
        'Expert-RunVerify.ps1'      = 2
        'Fleet-Handoff.ps1'         = 2
        'Publish-DocsWiki.ps1'      = 2
        'Resolve-SkillOwner.ps1'    = 1
        'Fleet-Plan.ps1'            = 1
        'Fleet-Supervisor.ps1'      = 1
        'Get-ToolkitFreshness.ps1'  = 1
        'Install-RepoTemplates.ps1' = 1
        'Apply-LabelPreset.ps1'     = 1
        'Board-Handoff.ps1'         = 1
    }
}

Describe 'Raw gh lint - the wrapper is the only door that gets wider (#571)' {
    It 'every script matches its frozen raw-gh count EXACTLY - a ratchet, not a ceiling' {
        # Exact match on purpose (external review round 1): a ceiling left headroom - migrate
        # one call without lowering the baseline, and a later NEW raw call hides in the gap.
        # Count went UP -> a new raw call (regression). Count went DOWN -> good work, lower the
        # baseline entry so the gain is locked in.
        $violations = @()
        foreach ($f in Get-ChildItem -LiteralPath $script:ScriptsDir -Filter *.ps1 |
                 Where-Object { $_.Name -ne 'Invoke-Gh.ps1' }) {
            $count = script:Get-RawGhCount -Path $f.FullName
            $allowed = if ($script:Baseline.ContainsKey($f.Name)) { $script:Baseline[$f.Name] } else { 0 }
            if ($count -gt $allowed) {
                $violations += "{0}: {1} raw gh call(s), baseline {2} - route new calls through Invoke-Gh (#303: bare gh turns a 401 into an empty result)" -f $f.Name, $count, $allowed
            } elseif ($count -lt $allowed) {
                $violations += "{0}: {1} raw gh call(s), baseline {2} - lower this file's baseline entry to {1} so the reduction is locked in" -f $f.Name, $count, $allowed
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'no baseline entry points at a file that no longer exists' {
        $stale = @()
        foreach ($name in $script:Baseline.Keys) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:ScriptsDir $name))) { $stale += "$name (file gone)" }
        }
        $stale | Should -BeNullOrEmpty
    }
}
