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

# ── Pure core ───────────────────────────────────────────────────────────────────

function Format-EvidenceBlock {
    param([object[]]$Results)
    $rows = @($Results)
    $passed = @($rows | Where-Object { "$($_.result)".ToUpperInvariant() -eq 'PASS' }).Count
    $failed = @($rows | Where-Object { "$($_.result)".ToUpperInvariant() -eq 'FAIL' }).Count
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<!-- [abios-evidence] -->')
    $lines.Add('## Evidence')
    $lines.Add('')
    $lines.Add("**Summary:** $passed passed / $failed failed")
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
        [string]$Branch = ''
    )
    $rows = @($Results)
    $passed = @($rows | Where-Object { "$($_.result)".ToUpperInvariant() -eq 'PASS' }).Count
    $failed = @($rows | Where-Object { "$($_.result)".ToUpperInvariant() -eq 'FAIL' }).Count
    $path = "evidence/$Issue.md"
    $link = if ($Repo -and $Branch) { "[$path](https://github.com/$Repo/blob/$Branch/$path)" } else { "``$path``" }
    @(
        '<!-- [abios-evidence] -->'
        '## Evidence'
        ''
        "**Summary:** $passed passed / $failed failed"
        ''
        "Full evidence (single source of truth): $link"
    ) -join "`n"
}

# Dot-source guard: tests set $env:ABIOS_EXPERTEVIDENCE_DOTSOURCE to load the pure core only.
if ($env:ABIOS_EXPERTEVIDENCE_DOTSOURCE) { return }

# This module is consumed by Expert-Auto.ps1 (which passes the collected results + the resolved
# contract and writes the block to each Get-EvidenceTargets destination). Invoked directly with
# no arguments it is a no-op — the formatting core is the reusable surface.
