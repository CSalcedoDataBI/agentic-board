<#
.SYNOPSIS
    Decide whether an autonomous run may close its own work end-to-end (#530, part of #526).

.DESCRIPTION
    The owner's rule, stated 2026-07-30:

      "Quiero que esto se cumpla cuando soy yo el que doy tambien una orden directa y le digo
       llevar de punta a punta. Pero quiero agregar que en ese de punta a punta, si se pueden hacer
       pruebas automaticas es fenomenal, y que la misma herramienta haga sus test; yo hago los mios
       al final."

    Two things, not one:

      1. END-TO-END IS AN ORDER, not a stored setting. A config written weeks ago is not the same
         as "this one, now, take it to the end". The permission travels with the instruction and is
         good for THAT run.
      2. IN THAT MODE THE RUN TESTS ITS OWN WORK. It does not delegate verification to CI or assume
         it. The owner tests AT THE END, on something already verified - his check is the last word,
         not the first safety net.

    So permission is never one condition. It is four, every one of them established against the
    CURRENT head commit, and a missing one is NAMED rather than swallowed:

      - the owner ordered it                          (permission travels with the instruction)
      - the change is code-class                      (#529 - what he judges by looking stays his)
      - a real review exists for this commit          (#510 - a green check is not a review)
      - automated tests ran and left evidence         ("testable and untested" is not finished)

    WHY ALL FOUR RATHER THAN A PRIORITY ORDER: each covers a failure the others cannot see. A
    reviewed, tested change that is a dashboard is still his to approve. An ordered, reviewed,
    code-class change that nobody ran is still unverified. Collapsing them into one flag is how a
    control ends up meaning less than it says - the defect this repo has now found in its brake
    (#440), its review gate (#510) and its own evidence blocks (#479).

    Pure (no side effects) behind a dot-source guard ($env:ABIOS_ENDTOEND_DOTSOURCE).

.EXAMPLE
    . .\Expert-EndToEnd.ps1
    Test-EndToEndAllowed -Ordered $true -WorkClass 'code' -ReviewedHead $true -TestsRecorded $true
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Load the classifier's PURE core once, with its dot-source guard set. Without the guard, and done
# from inside the function, every call also ran Expert-WorkClass's CLI section: a `git diff` plus a
# printed banner per invocation. A decision function with a side effect per call is not a decision
# function - and here it would have run git while deciding whether a merge is allowed.
$prevWc = $env:ABIOS_WORKCLASS_DOTSOURCE
$env:ABIOS_WORKCLASS_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-WorkClass.ps1')
$env:ABIOS_WORKCLASS_DOTSOURCE = $prevWc

# ── Pure core ───────────────────────────────────────────────────────────────────

<#
    May this run close its own work?

    Returns @{ allowed; missing; reason }. `missing` lists every unmet condition - all of them, not
    just the first: telling someone one reason at a time, forcing a round trip per condition, is
    its own kind of dishonesty about how far the work actually is.

    $TestsRequired comes from the CONTRACT's definition of done (`dod.tests`), never from the run's
    own opinion of whether its change was testable. A per-run "no se podia probar" is exactly the
    self-issued excuse this module exists to remove; a project that genuinely has no automated
    tests says so once, in writing, in its contract.
#>
function Test-EndToEndAllowed {
    param(
        [bool]$Ordered = $false,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorkClass,
        [hashtable]$WorkClassPolicy,
        [bool]$ReviewedHead = $false,
        [bool]$TestsRecorded = $false,
        [bool]$TestsRequired = $true,
        # Does CI exist on this commit at all? Separate from $TestsRecorded (is it green) because
        # waiving the REQUIREMENT for a test suite must never waive a suite that ran and FAILED.
        # Defaults to $true: assuming a project has no CI is the permissive assumption.
        [bool]$CiPresent = $true
    )
    $missing = @()

    if (-not $Ordered) {
        $missing += 'la orden explicita de llevarlo de punta a punta (sin ella, nada se cierra solo)'
    }
    if (Test-HumanMustApprove -Class $WorkClass -Policy $WorkClassPolicy) {
        $why = if ("$WorkClass".Trim().ToLowerInvariant() -eq 'unknown') {
            'no se pudo determinar que cambio'
        } else {
            "el cambio es de clase '$WorkClass' - se juzga mirandolo"
        }
        $missing += "que el cambio sea codigo ($why)"
    }
    if (-not $ReviewedHead) {
        $missing += 'una revision real de ESTE commit (un check verde no es una revision)'
    }
    if ($TestsRequired -and -not $TestsRecorded) {
        $missing += 'constancia de que corrieron pruebas automaticas sobre este commit'
    } elseif ($CiPresent -and -not $TestsRecorded) {
        # The contract does not demand a test suite, but CI EXISTS on this commit and is not green.
        # Waiving "you must have tests" never waives "the tests you have must pass" (#539).
        $missing += 'que el CI de este commit este en verde (existe y no lo esta - eso no lo exime el contrato)'
    }

    if ($missing.Count -eq 0) {
        return @{
            allowed = $true
            missing = @()
            reason  = 'ordenado punta a punta, es codigo, revisado y probado sobre este commit'
        }
    }
    return @{
        allowed = $false
        missing = @($missing)
        reason  = "falta: $($missing -join '; ')"
    }
}

<#
    Did CI actually run and pass on this commit?

    Takes the RAW `gh pr checks --json name,bucket` output rather than calling gh itself, so the
    one condition that cannot be self-issued is testable without a network round-trip - and so the
    caller is forced to hand over the checks of a PR it actually resolved. That mattered: the
    caller used to pass a PR number that a dot-source had reset to 0, and this decision silently
    became "no checks -> not tested" for every run (#536).

    Green means: at least one check PASSED and none is failing, pending or cancelled. Counting
    "nothing failed" as tested let a PR whose only check was SKIPPED satisfy the requirement, with
    no CI having run on that commit at all. Unreadable or empty input is NOT a pass - "I could not
    look" is not evidence.
#>
<#
    Read a contract's `dod.tests` as a real boolean.

    `[bool]$contract.dod['tests']` was the same trap already closed for the brake marker's
    `endToEnd`: PowerShell casts ANY non-empty string to $true, so a contract serialising
    "false" — by hand, or through a JSON writer that quotes booleans — read as "tests required"
    when it said the opposite. It failed safe, but the behaviour depended on the contract always
    emitting real JSON booleans, which is exactly the assumption this repo keeps finding wrong.

    Absent, null or unrecognisable means REQUIRED: the safe direction, and the one a project that
    never thought about it should get.
#>
function Get-TestsRequired {
    param($Contract)
    if ($Contract -isnot [hashtable]) { return $true }
    if ($Contract.dod -isnot [hashtable]) { return $true }
    if (-not $Contract.dod.ContainsKey('tests')) { return $true }
    $v = $Contract.dod['tests']
    if ($v -is [bool]) { return [bool]$v }
    # A string or number only DISABLES the requirement when it unambiguously says so.
    $s = "$v".Trim().ToLowerInvariant()
    if ($s -in @('false','0','no')) { return $false }
    if ($s -in @('true','1','yes')) { return $true }
    return $true
}

function Test-CiChecksPassed {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ChecksJson)
    return (Get-CiEvidence -ChecksJson $ChecksJson).passed
}

<#
    Split the CI question in two, because collapsing them was a false-permission path (#539).

    "Does this project have to run automated tests?" is the CONTRACT's call (dod.tests).
    "Is the CI that actually exists green?" is never the contract's call, and never waivable.

    Reading only `passed` conflated four states - no checks, pending checks, failed checks and an
    unreadable answer - so a project declaring no test suite would close a PR whose CI was RED.
    Board-Merge can fall back to --admin, so the ruleset would not have stopped it either.

    `present` is deliberately TRUE for unreadable output: "I could not read the checks" must not be
    laundered into "this project has no CI", which is the permissive reading.
#>
function Get-CiEvidence {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ChecksJson)
    if ([string]::IsNullOrWhiteSpace($ChecksJson)) {
        return @{ present = $false; passed = $false }
    }
    try {
        $arr = @($ChecksJson | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return @{ present = $true; passed = $false }
    }
    if ($arr.Count -eq 0) { return @{ present = $false; passed = $false } }
    $bad    = @($arr | Where-Object { "$($_.bucket)" -notin @('pass','skipping') })
    $passed = @($arr | Where-Object { "$($_.bucket)" -eq 'pass' })
    return @{ present = $true; passed = ($passed.Count -gt 0 -and $bad.Count -eq 0) }
}

# Render the decision for a human. Kept next to the decision so the refusal and its wording cannot
# drift apart - a refusal nobody understands gets worked around instead of fixed.
function Format-EndToEndVerdict {
    param([Parameter(Mandatory)][hashtable]$Verdict)
    if ($Verdict.allowed) {
        return "PUNTA A PUNTA: permitido - $($Verdict.reason)."
    }
    $lines = @("PUNTA A PUNTA: no se cierra solo. Falta:")
    foreach ($m in @($Verdict.missing)) { $lines += "  - $m" }
    $lines += "Deja el PR listo y con el gate en verde; el cierre lo hace una persona."
    return ($lines -join "`n")
}

# Dot-source guard: tests set $env:ABIOS_ENDTOEND_DOTSOURCE to load the pure core only.
if ($env:ABIOS_ENDTOEND_DOTSOURCE) { return }

