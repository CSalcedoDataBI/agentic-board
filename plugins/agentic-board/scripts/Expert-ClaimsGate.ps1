<#
.SYNOPSIS
    Claims verification gate for /board expert deliverables (#479).

.DESCRIPTION
    Extends the evidence contract from "tests ran" to "claims were checked".

    An autonomous run can produce fully green DoD evidence while every factual claim
    in its deliverable is invented — the evidence block records test results, not claim
    correctness. This gate closes that gap: when a deliverable asserts external facts
    (a package exists, a CLI flag is supported, an API exposes specific tools), those
    claims must appear in the evidence block as verified, unverified, or not-applicable.

    A claim is one of three states:
      verified   — the run looked it up; howChecked records the method, correct records the result
      unverified — explicitly acknowledged as unchecked; the gap is visible, not hidden
      not-applicable — the deliverable makes no external claims (empty claims list)

    Gate logic (Test-ClaimsGate):
      empty list             → not-applicable → pass (no friction for code-only runs)
      all verified + correct → verified → pass
      any verified + wrong   → claims-failed → FAIL (the DoD cannot go green silently)
      any unverified         → has-unverified → pass (gap is visible in the evidence block)

    Verified+wrong takes precedence over unverified when both are present.

    Pure functions (Test-ClaimsGate, Format-ClaimsSection) behind
    $env:ABIOS_EXPERTCLAIMSGATE_DOTSOURCE for unit tests without a network round-trip.

.EXAMPLE
    . .\Expert-ClaimsGate.ps1
    $claims = @(
        @{ claim='mcp-server-gsc'; kind='npm-package'; status='verified'; howChecked='npm view mcp-server-gsc'; correct=$true }
    )
    Test-ClaimsGate -Claims $claims
    Format-ClaimsSection -Claims $claims
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

<#
    Evaluate the claims gate for a set of claim verification records.

    Each record is a hashtable or PSObject with:
      claim      (string)  — the claim text, e.g. '@ahonn/mcp-server-gsc'
      kind       (string)  — npm-package | cli-flag | api-tool | auth-mechanism | other
      status     (string)  — 'verified' | 'unverified'
      howChecked (string)  — how it was looked up (e.g. 'npm view pkg')
      correct    ($true/$false/$null) — $true=exists/correct, $false=wrong/404, $null=not checked

    Returns @{ pass; gateStatus; flagged; summary }

    gateStatus values:
      not-applicable  — claims list is empty; the gate does not apply
      verified        — all claims verified and all correct
      has-unverified  — at least one claim is explicitly unverified (visible gap)
      claims-failed   — at least one verified claim is incorrect (pass=$false)

    Verified+wrong takes precedence over unverified when both are present.
#>
function Test-ClaimsGate {
    param([object[]]$Claims = @())
    $rows = @($Claims | Where-Object { $_ -ne $null })

    if ($rows.Count -eq 0) {
        return @{
            pass       = $true
            gateStatus = 'not-applicable'
            flagged    = @()
            summary    = 'No external claims — gate not applicable.'
        }
    }

    $flagged = @($rows | Where-Object {
        "$($_.status)" -eq 'verified' -and $_.correct -eq $false
    } | ForEach-Object { "$($_.claim)" })

    if ($flagged.Count -gt 0) {
        return @{
            pass       = $false
            gateStatus = 'claims-failed'
            flagged    = $flagged
            summary    = "$($flagged.Count) claim(s) verified as incorrect: $($flagged -join '; ')"
        }
    }

    $hasUnverified = [bool]@($rows | Where-Object { "$($_.status)" -eq 'unverified' })

    if ($hasUnverified) {
        $uvCount = @($rows | Where-Object { "$($_.status)" -eq 'unverified' }).Count
        return @{
            pass       = $true
            gateStatus = 'has-unverified'
            flagged    = @()
            summary    = "$uvCount unverified claim(s) — gap is visible in the evidence block."
        }
    }

    return @{
        pass       = $true
        gateStatus = 'verified'
        flagged    = @()
        summary    = "All $($rows.Count) claim(s) verified and correct."
    }
}

<#
    Render a claims section for inclusion in an evidence block.

    Three distinct status labels, never collapsed:
      PASS        — status=verified, correct=$true
      FAIL        — status=verified, correct=$false
      UNVERIFIED  — status=unverified (explicitly acknowledged as unchecked)

    When the claims list is empty, renders a not-applicable notice — the
    common case (a code-only run) is represented explicitly, not silently absent.
#>
function Format-ClaimsSection {
    param([object[]]$Claims = @())
    $rows = @($Claims | Where-Object { $_ -ne $null })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('## Claims')
    $lines.Add('')

    if ($rows.Count -eq 0) {
        $lines.Add('**Status:** not-applicable — this run made no external claims in its deliverable.')
        return ($lines -join "`n")
    }

    $lines.Add('| Claim | Kind | Status | How Checked |')
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($r in $rows) {
        $claim      = "$($r.claim)"      -replace '\|', '\|'
        $kind       = "$($r.kind)"       -replace '\|', '\|'
        $howChecked = "$($r.howChecked)" -replace '\|', '\|'
        $label = if ("$($r.status)" -eq 'verified') {
            if ($r.correct -eq $true)  { 'PASS' }
            elseif ($r.correct -eq $false) { 'FAIL' }
            else { 'verified (result unknown)' }
        } else {
            'UNVERIFIED'
        }
        $lines.Add("| $claim | $kind | $label | $howChecked |")
    }
    ($lines -join "`n")
}

# Dot-source guard: tests set $env:ABIOS_EXPERTCLAIMSGATE_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTCLAIMSGATE_DOTSOURCE) { return }

# This module is consumed by Expert-Auto.ps1 and the evidence recording step.
# Invoked directly with no arguments it is a no-op — the pure core is the reusable surface.
