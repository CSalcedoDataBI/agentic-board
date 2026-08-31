<#
.SYNOPSIS
    The closing summary every user-facing flow ends with — four blocks, always the same four.

.DESCRIPTION
    Reported by the product owner, a BI professional and not a programmer: the tool ends each
    command however that command's author felt like ending it, so there is no fixed place to
    look for the only four things a user actually wants to know —

        what I found · what I did · what is left · what I need from you

    This renders exactly those, in that order, always. Two rules make it readable rather than
    merely present:

      - **An empty block says so out loud.** Silence is unreadable: a blank "what I need from
        you" is indistinguishable from a summary that was cut off. Every empty block renders an
        explicit sentence instead.
      - **The order never changes**, whatever order the caller passes the blocks in. The value
        of a fixed shape is that the eye stops reading and starts scanning.

    Wording is Spanish and unaccented, matching the existing console surface (Board-Work and
    friends already print "sesion", "Iniciados"): this file is the renderer, not the place to
    change the console's language or its encoding conventions.

    Pure formatting behind a dot-source guard ($env:ABIOS_BOARDSUMMARY_DOTSOURCE); the writer
    half is one thin function.

.EXAMPLE
    . .\Board-Summary.ps1
    Write-ClosingSummary -Title 'Listo' -Did 'Abri el PR #489' -NeedFromYou 'Revisar y mergear'
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

# The contract. Order is meaning here — do not reorder without changing the tests that pin it.
$script:ClosingSummaryBlocks = @(
    @{ Key = 'Found';       Label = 'Que encontre';        Empty = 'Nada fuera de lo esperado.' }
    @{ Key = 'Did';         Label = 'Que hice';            Empty = 'Nada — no se cambio nada.' }
    @{ Key = 'Pending';     Label = 'Que queda pendiente'; Empty = 'Nada — no quedo trabajo abierto.' }
    @{ Key = 'NeedFromYou'; Label = 'Que necesito de ti';  Empty = 'Nada — esto quedo listo.' }
)

function Get-ClosingSummaryBlocks {
    <#  The contract as DATA, for the second consumer.

        The renderer below is only half the surface: most of what the user reads is written by
        the agent following commands/*.md, not printed by a script. Those prompts must demand
        the same four blocks, with the same headings and the same when-empty sentences — and a
        paraphrase hand-copied into seven files is a paraphrase that drifts (#200/#202 is the
        same lesson for the README). So the prompt text is GENERATED from this list by
        Update-Docs.ps1: change a label here and every command file goes stale until it is
        regenerated, which the docs-freshness gate reports. #>
    [CmdletBinding()]
    param()
    foreach ($b in $script:ClosingSummaryBlocks) {
        [pscustomobject]@{ Key = $b.Key; Label = $b.Label; Empty = $b.Empty }
    }
}

function Format-ClosingSummary {
    [CmdletBinding()]
    param(
        [string]  $Title       = '',
        [string[]]$Found       = @(),
        [string[]]$Did         = @(),
        [string[]]$Pending     = @(),
        [string[]]$NeedFromYou = @(),
        [switch]  $AsMarkdown
    )
    $content = @{ Found = $Found; Did = $Did; Pending = $Pending; NeedFromYou = $NeedFromYou }
    $lines   = [System.Collections.Generic.List[string]]::new()

    if ($AsMarkdown) { $lines.Add('<!-- [abios-summary] -->') }

    if ($Title) {
        $lines.Add($(if ($AsMarkdown) { "# $Title" } else { $Title }))
        $lines.Add('')
    }

    foreach ($block in $script:ClosingSummaryBlocks) {
        $items = @($content[$block.Key] | Where-Object { "$_".Trim() })
        $lines.Add($(if ($AsMarkdown) { "## $($block.Label)" } else { "$($block.Label):" }))
        if ($items.Count) {
            foreach ($item in $items) { $lines.Add("- $item") }
        } else {
            # Never a blank block: the reader must be told "nothing", not left to infer it.
            $lines.Add("- $($block.Empty)")
        }
        $lines.Add('')
    }

    (($lines -join "`n").TrimEnd())
}

function Write-ClosingSummary {
    <# Thin host writer, so a command ends with one call instead of hand-rolled Write-Host. #>
    [CmdletBinding()]
    param(
        [string]  $Title       = '',
        [string[]]$Found       = @(),
        [string[]]$Did         = @(),
        [string[]]$Pending     = @(),
        [string[]]$NeedFromYou = @()
    )
    $text = Format-ClosingSummary -Title $Title -Found $Found -Did $Did `
                                  -Pending $Pending -NeedFromYou $NeedFromYou
    Write-Host ''
    foreach ($line in ($text -split "`n")) {
        $color = if ($line -match ':$') { 'Cyan' } else { 'Gray' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
}

# Dot-source guard: tests set $env:ABIOS_BOARDSUMMARY_DOTSOURCE to load the pure core only.
if ($env:ABIOS_BOARDSUMMARY_DOTSOURCE) { return }

# Consumed by the command surfaces (#493 threads it through them) and by the autonomous run's
# end-of-run report. Invoked directly with no arguments it is a no-op — the renderer is the
# reusable surface.
