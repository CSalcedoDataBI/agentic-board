<#
.SYNOPSIS
    Evidence logging for /board expert — format the recorded test evidence and pick its
    destinations (PR body, [abios-evidence] issue comment, versioned file).

.DESCRIPTION
    "It is hard to know that tests were actually run." This makes the proof explicit and
    traceable: Format-EvidenceBlock renders a structured, durably-marked block (what was
    tested, the command, the result, detail) with a pass/fail summary; Get-EvidenceTargets
    reads the contract to decide where it lands. The auto-expert writes the block to every
    enabled destination after each verify phase.

    Pure formatting behind a dot-source guard ($env:ABIOS_EXPERTEVIDENCE_DOTSOURCE); the CLI
    half (writing to gh/PR/file) is thin and reuses Invoke-Gh.

.EXAMPLE
    . .\Expert-Evidence.ps1 ; Format-EvidenceBlock -Results $runs
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Get-ApplicableDodGates lives with the work classifier. Loaded with ITS dot-source guard set so
# only the pure core comes in - without it, dot-sourcing here would also run its CLI (a git diff
# and a printed banner).
$prevWc = $env:ABIOS_WORKCLASS_DOTSOURCE
$env:ABIOS_WORKCLASS_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-WorkClass.ps1')
$env:ABIOS_WORKCLASS_DOTSOURCE = $prevWc

# ── Pure core ───────────────────────────────────────────────────────────────────

<#
    The four honest outcomes of a gate (#475, #481). A row used to be PASS or FAIL, so a gate that
    could not run had only two ways to be recorded - and both were lies: PASS claims a check
    happened, FAIL claims the run's code broke it.

      PASS           the gate ran and passed
      FAIL           the gate ran and failed
      N/A            NOT APPLICABLE: nothing in this change triggers the gate (a `bpa` gate in a
                     repo with no semantic model). It is a statement about the CHANGE.
      NOT-EVALUATED  the gate applies but could not be evaluated (CI ended in startup_failure, or
                     a job was refused before its first step). It is a statement about the
                     ENVIRONMENT, and it is never a pass.

    Returns 'pass' / 'fail' / 'na' / 'not-evaluated', or '' for anything else (a free-text result
    such as 'PARTIAL' is left uncounted rather than forced into a bucket it does not belong to).
    Synonyms are accepted because the rows are written by a run, not by this module.
#>
function Get-EvidenceState {
    param([AllowNull()][AllowEmptyString()][string]$Result)
    $r = "$Result".Trim().ToUpperInvariant() -replace '[\s_]+', '-'
    switch ($r) {
        'PASS'            { return 'pass' }
        'FAIL'            { return 'fail' }
        { $_ -in @('N/A','NA','NOT-APPLICABLE') }                       { return 'na' }
        { $_ -in @('NOT-EVALUATED','NOTEVALUATED','NOT-RUN','NOT-RAN') } { return 'not-evaluated' }
        default           { return '' }
    }
}

# "3 passed / 1 failed" - with the two honest non-outcomes appended ONLY when present, so a run
# that never needed them produces the same line it always did and nothing that parses it moves.
function Format-EvidenceSummary {
    param([object[]]$Rows)
    $states = @(@($Rows) | ForEach-Object { Get-EvidenceState -Result "$($_.result)" })
    $passed = @($states | Where-Object { $_ -eq 'pass' }).Count
    $failed = @($states | Where-Object { $_ -eq 'fail' }).Count
    $na     = @($states | Where-Object { $_ -eq 'na' }).Count
    $ne     = @($states | Where-Object { $_ -eq 'not-evaluated' }).Count
    $s = "$passed passed / $failed failed"
    if ($na -gt 0) { $s += " / $na not applicable" }
    if ($ne -gt 0) { $s += " / $ne not evaluated" }
    $s
}

function Format-EvidenceBlock {
    param([object[]]$Results)
    $rows = @($Results)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<!-- [abios-evidence] -->')
    $lines.Add('## Evidence')
    $lines.Add('')
    $lines.Add("**Summary:** $(Format-EvidenceSummary -Rows $rows)")
    $lines.Add('')
    $lines.Add('| Test | Command | Result | Detail |')
    $lines.Add('| --- | --- | --- | --- |')
    foreach ($r in $rows) {
        $name = "$($r.name)"    -replace '\|', '\|'
        $cmd  = "$($r.command)" -replace '\|', '\|'
        $res  = "$($r.result)"  -replace '\|', '\|'
        $det  = "$($r.detail)"  -replace '\|', '\|'
        $lines.Add("| $name | $cmd | $res | $det |")
    }
    ($lines -join "`n")
}

function Get-EvidenceTargets {
    param([Parameter(Mandatory)][hashtable]$Contract)
    $ev = $Contract.evidence
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'pr','issueComment','file') {
        if ($ev -and $ev.ContainsKey($k) -and $ev[$k]) { $out.Add($k) }
    }
    $out.ToArray()
}

<#
    The LINK STUB for the PR body and the issue comment (#570).

    The full block used to be COPIED to three destinations - the same content written three ways,
    drifting independently and re-verified separately (the "INCOMPLETE -> record -> re-run" loop
    mostly existed to keep three copies in sync). Now the versioned file is the single source of
    truth and the other two surfaces carry this stub: the durable [abios-evidence] marker, the
    summary line, and the path/link to the file. Pure.
#>
function Format-EvidenceLinkStub {
    param(
        [Parameter(Mandatory)][int]$Issue,
        [object[]]$Results = @(),
        [string]$Repo = '',
        # The DEFAULT/base branch, not the PR branch (review round 3): the merge flow deletes the
        # PR branch, so a branch-pinned link 404s exactly when the comment becomes the durable
        # record. The default-branch link is a 404 only until the merge, then correct forever.
        [string]$BaseBranch = ''
    )
    $rows = @($Results)
    $path = "evidence/$Issue.md"
    $link = if ($Repo -and $BaseBranch) { "[$path](https://github.com/$Repo/blob/$BaseBranch/$path)" } else { "``$path``" }
    @(
        '<!-- [abios-evidence] -->'
        '## Evidence'
        ''
        "**Summary:** $(Format-EvidenceSummary -Rows $rows)"
        ''
        "Full evidence (single source of truth): $link"
    ) -join "`n"
}

<#
    Evidence rows for the DoD gates the contract enabled but THIS change does not owe (#475).

    Get-ApplicableDodGates (Expert-WorkClass.ps1) already stops a run from being held to a gate
    its diff cannot trigger; what it could not do was say so in the record. Without a row, a
    reader six months later cannot tell "bpa passed" from "bpa was never applicable" - both were
    simply absent, or worse, the second was written as PASS. Each row is N/A with the reason.

    An unreadable diff (empty path list) owes every enabled gate, so it produces NO N/A rows:
    "I could not see what changed" must never excuse a check. Pure.
#>
function Get-NotApplicableGateRows {
    param(
        [hashtable]$Dod = @{},
        [string[]]$ChangedPaths = @()
    )
    $paths = @(@($ChangedPaths) | Where-Object { "$_".Trim() })
    # No guard for the empty list on purpose: Get-ApplicableDodGates already answers "every
    # enabled gate" for it, so owed == enabled and no N/A row is produced (pinned by a test).
    $owed    = @(Get-ApplicableDodGates -Dod $Dod -ChangedPaths $paths)
    $enabled = @(Get-ApplicableDodGates -Dod $Dod -ChangedPaths @())
    $reason = @{
        bpa          = 'no semantic-model file (.tmdl/.bim/.pbism) in this change'
        tmdlbreaking = 'no semantic-model file (.tmdl/.bim/.pbism) in this change'
        build        = 'nothing executable changed (docs, images and data files only)'
        lint         = 'nothing executable changed (docs, images and data files only)'
        tests        = 'nothing executable changed (docs, images and data files only)'
    }
    @($enabled | Where-Object { $owed -notcontains $_ } | ForEach-Object {
        $why = $reason["$_".ToLowerInvariant()]
        if (-not $why) { $why = 'nothing in this change triggers this gate' }
        @{ name = "$_"; command = '(gate does not apply to this change)'; result = 'N/A'; detail = $why }
    })
}

<#
    The evidence row for the CI gate, from a CI state (Get-CiState in CiCheckState.ps1) (#481).

    passed         -> PASS
    failed         -> FAIL          (the code is broken: keep working)
    not-evaluated  -> NOT-EVALUATED (CI never ran: stop re-pushing, say so plainly)
    none           -> N/A           (a clean read found no CI on this commit)
    pending / unreadable -> no row  (not a settled fact yet; recording one would be inventing it)

    Returns $null for the last case so a caller cannot write a row by accident. Pure.
#>
function Get-CiEvidenceRow {
    param(
        [AllowEmptyString()][string]$CiState,
        [string[]]$Checks = @(),
        [string]$Command = 'gh pr checks --json name,bucket,state,link'
    )
    $names = (@($Checks) | Where-Object { "$_".Trim() }) -join ', '
    switch ("$CiState".Trim().ToLowerInvariant()) {
        'passed' {
            return @{ name = 'ci'; command = $Command; result = 'PASS'; detail = 'all checks green' }
        }
        'failed' {
            $d = if ($names) { "failing: $names" } else { 'a check failed' }
            return @{ name = 'ci'; command = $Command; result = 'FAIL'; detail = $d }
        }
        'not-evaluated' {
            $d = 'CI never executed (startup_failure, or a job refused before its first step) - not a failure of this change'
            if ($names) { $d = "$d; affected: $names" }
            return @{ name = 'ci'; command = $Command; result = 'NOT-EVALUATED'; detail = $d }
        }
        'none' {
            return @{ name = 'ci'; command = $Command; result = 'N/A'; detail = 'no CI checks reported for this commit' }
        }
        default { return $null }
    }
}

# Dot-source guard: tests set $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTEVIDENCE_DOTSOURCE) { return }

# This module is consumed by Expert-Auto.ps1 (which passes the collected results + the resolved
# contract and writes the block to each Get-EvidenceTargets destination). Invoked directly with
# no arguments it is a no-op — the formatting core is the reusable surface.
