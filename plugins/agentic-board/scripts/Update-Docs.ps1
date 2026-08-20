<#
.SYNOPSIS
    Regenerate the derived parts of README.md so they never drift from the source:
    the command catalog (from each command's frontmatter) and the version string
    (from plugin.json). Rewrites only the content between named markers.

.DESCRIPTION
    The README carries two facts that are really owned elsewhere:

      * the command catalog  -> owned by the frontmatter `description:` of each
        commands/*.md file (the single source of truth for what a command does);
      * the current version  -> owned by plugin.json.

    Hand-copying either into prose invites drift (#200: "the README is
    hand-maintained so it drifts"). This generator (#202) reads the sources and
    rewrites just the marked regions, byte-preserving everything else:

        <!-- BEGIN:commands ... -->   ... generated command table ...   <!-- END:commands -->
        <!-- BEGIN:version -->vX.Y.Z<!-- END:version -->

    Everything outside those markers is left untouched, so the editorial prose
    around them is safe to keep hand-writing.

    It also owns a third derived region, this one in EVERY commands/*.md file
    (#493):

        <!-- BEGIN:closing-summary -->  ... the four-block contract ...  <!-- END:closing-summary -->

    Its source is the renderer (Board-Summary.ps1), so the four blocks an agent
    is told to write are literally the four blocks a script prints. A command
    file with no such region FAILS rather than being skipped - otherwise a newly
    added command would ship with no closing contract and nothing would notice.

.PARAMETER Check
    Read-only: regenerate in memory and compare to what is on disk. Writes
    nothing. Exit 1 if the README is stale (so the docs-freshness gate #203 can
    call it), 0 if it is already current. Names which region drifted.

.PARAMETER DryRun
    Print what would change (which regions are stale) without writing.

.PARAMETER ReadmePath
    Override the README path (defaults to the repo-root README.md). Mainly for
    tests.

.EXAMPLE
    .\Update-Docs.ps1 -Check      # gate: exit 1 if the README is stale
    .\Update-Docs.ps1 -DryRun     # preview
    .\Update-Docs.ps1             # rewrite the marked regions in place
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [string]$ReadmePath = ''
)

# ------------------------------------------------------------------ pure helpers

# Pull a single scalar field out of a Markdown frontmatter block (the leading
# `---` ... `---` fence). Returns the trimmed value, or $null when the field is
# absent. Pure -> unit-testable.
function Get-FrontmatterField {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory)][string]$Field
    )
    $m = [regex]::Match($Raw, '(?s)^\s*---\r?\n(.*?)\r?\n---')
    if (-not $m.Success) { return $null }
    $block = $m.Groups[1].Value
    $fm = [regex]::Match($block, '(?m)^' + [regex]::Escape($Field) + '\s*:\s*(.+?)\s*$')
    if (-not $fm.Success) { return $null }
    $fm.Groups[1].Value.Trim()
}

# Build the command catalog from a directory of `*.md` command files. Each file's
# base name becomes the `/command` and its frontmatter `description` the blurb.
# Files without a description are skipped (they are not real entry-point commands).
# Returned sorted by name for a stable, deterministic diff. Pure -> testable.
function Get-CommandCatalog {
    param([Parameter(Mandatory)][string]$CommandsDir)
    if (-not (Test-Path $CommandsDir)) { throw "Commands directory not found: $CommandsDir" }
    $rows = foreach ($f in (Get-ChildItem -Path $CommandsDir -Filter '*.md' -File)) {
        $raw  = [System.IO.File]::ReadAllText($f.FullName)
        $desc = Get-FrontmatterField -Raw $raw -Field 'description'
        if (-not $desc) { continue }
        [pscustomobject]@{
            Name        = '/' + $f.BaseName
            Description = $desc
        }
    }
    @($rows | Sort-Object Name)
}

# Render the catalog rows as a GitHub-flavored Markdown table. A `|` inside a
# description would break the table, so escape it. Pure -> testable.
function Format-CatalogTable {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $lines = @('| Command | What it does |', '|---|---|')
    foreach ($r in $Rows) {
        # Escape only pipes that are not already backslash-escaped, so a description
        # an author wrote as `a \| b` is not double-escaped into `a \\| b`.
        $desc = $r.Description -replace '(?<!\\)\|', '\|'
        $lines += "| ``$($r.Name)`` | $desc |"
    }
    $lines -join "`n"
}

# Render the closing-summary contract as the instruction block every command file carries
# (#493). The four headings and their when-empty sentences come from the renderer
# (Board-Summary.ps1 -> Get-ClosingSummaryBlocks), so the text an agent is told to write and
# the text a script prints can never disagree. Pure -> testable.
function Format-ClosingSummaryPrompt {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Blocks)
    if (-not $Blocks -or $Blocks.Count -eq 0) { throw "Format-ClosingSummaryPrompt: no blocks supplied - the closing-summary contract cannot be empty." }
    $lines = @(
        '**Closing summary — required (#491).** End your reply to the user with these four blocks,'
        'in this order, with these exact headings. Never drop one: when a block has nothing in it,'
        'write its when-empty sentence instead. A silent block is indistinguishable from an answer'
        'that got cut off, which is the failure this contract exists to remove.'
        ''
        '| # | Heading | When there is nothing to say |'
        '|---|---|---|'
    )
    $i = 0
    foreach ($b in $Blocks) {
        $i++
        $lines += "| $i | **$($b.Label)** | $($b.Empty) |"
    }
    $lines += @(
        ''
        'Write them in the language the user is speaking, in words a BI professional can act on.'
        'This block is generated from the shared renderer — to change the wording, change the'
        'renderer, not this text.'
    )
    $lines -join "`n"
}

# The newline a file predominantly uses. A Windows working copy with autocrlf
# checks README out as CRLF; emitting an LF-only generated region into it would
# read back as "stale" on every -Check and rewrite the region needlessly. So the
# generator matches the file's own newline. Pure -> testable.
function Get-DominantNewline {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -match "`r`n") { "`r`n" } else { "`n" }
}

# Read the version out of a plugin.json's raw text (same regex the release
# tooling uses). Pure -> testable.
function Get-PluginVersion {
    param([Parameter(Mandatory)][string]$Raw)
    $m = [regex]::Match($Raw, '"version"\s*:\s*"([^"]+)"')
    if (-not $m.Success) { throw "No version field found in plugin.json text." }
    $m.Groups[1].Value
}

# Decide what the closing-summary pass must do to a set of command files already read into
# memory: which need their region rewritten, and which are missing the markers altogether.
# Kept pure (no disk) so the decision itself is unit-tested rather than verified by hand —
# the epic's own Definition of Done is "asserted, not eyeballed", and that has to apply to
# the generator too, not only to what it generates.
#
# Each file is @{ Name = '<file>.md'; Text = '<raw contents>' }. Returns
# @{ Writes = @({Name, Text}); Missing = @('<file>.md') }.
function Get-CommandRegionPlan {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Files,
        [Parameter(Mandatory)][string]$Prompt
    )
    $writes  = @()
    $missing = @()
    foreach ($f in $Files) {
        $nl      = Get-DominantNewline -Text $f.Text
        # Match each file's own newline, or a CRLF working copy reads back as stale forever.
        $content = "$nl" + ($Prompt -replace "`r?`n", $nl) + "$nl"
        try {
            $new = Set-MarkedRegion -Text $f.Text -Name 'closing-summary' -Content $content
        } catch {
            # Both "no region at all" and "region is malformed" land here, and they need
            # different repairs — so carry the real reason instead of reporting every case as
            # "markers missing", which sends the reader looking for an absent marker when the
            # actual problem is a duplicated one.
            $missing += [pscustomobject]@{ Name = $f.Name; Reason = $_.Exception.Message }
            continue
        }
        if ($new -ne $f.Text) { $writes += [pscustomobject]@{ Name = $f.Name; Text = $new } }
    }
    [pscustomobject]@{ Writes = @($writes); Missing = @($missing) }
}

# Replace the text between a named marker pair with $Content, preserving the
# markers themselves and everything outside them. The BEGIN marker may carry a
# trailing note before `-->` (e.g. "do not edit"). Requires EXACTLY ONE region
# for the name so a stray marker can never be filled silently. $Content is spliced
# literally (no regex-replacement `$` interpretation). Pure -> testable.
function Set-MarkedRegion {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $n  = [regex]::Escape($Name)
    # Count BEGIN and END markers independently: matching only complete BEGIN..END
    # pairs would let a stray extra BEGIN (inside the region) or a trailing END slip
    # through, and the splice would silently mangle them. Require exactly one of each.
    $nb = ([regex]::Matches($Text, '<!--\s*BEGIN:' + $n + '\b[^>]*-->')).Count
    $ne = ([regex]::Matches($Text, '<!--\s*END:'   + $n + '\s*-->')).Count
    if ($nb -eq 0 -and $ne -eq 0) { throw "No '$Name' marker region found (expected <!-- BEGIN:$Name --> ... <!-- END:$Name -->)." }
    if ($nb -ne 1 -or $ne -ne 1) { throw "Malformed '$Name' markers: expected exactly one BEGIN and one END, found $nb BEGIN / $ne END." }
    $rx = [regex]::new(
        '(<!--\s*BEGIN:' + $n + '\b[^>]*-->)(.*?)(<!--\s*END:' + $n + '\s*-->)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $m = $rx.Match($Text)
    if (-not $m.Success) { throw "'$Name' markers are out of order (END appears before BEGIN)." }
    $Text.Substring(0, $m.Index) +
        $m.Groups[1].Value + $Content + $m.Groups[3].Value +
        $Text.Substring($m.Index + $m.Length)
}

# Dot-source guard: with $env:ABIOS_DOCS_DOTSOURCE set, return after defining the
# pure helpers WITHOUT touching disk - lets the tests unit-test them.
if ($env:ABIOS_DOCS_DOTSOURCE) { return }

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------- disk (side-effecting)
$repoRoot = (git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path }

if (-not $ReadmePath) { $ReadmePath = Join-Path $repoRoot 'README.md' }
$ReadmePath  = (Resolve-Path $ReadmePath).Path
$commandsDir = (Resolve-Path (Join-Path $PSScriptRoot '..' 'commands')).Path
$pluginJson  = (Resolve-Path (Join-Path $PSScriptRoot '..' '.claude-plugin' 'plugin.json')).Path

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Read as UTF-8 explicitly: Windows PowerShell's Get-Content -Raw decodes with the
# ANSI code page, which mangles the em dash in the frontmatter descriptions.
$readme    = [System.IO.File]::ReadAllText($ReadmePath)
$pluginRaw = [System.IO.File]::ReadAllText($pluginJson)

$catalog = Get-CommandCatalog -CommandsDir $commandsDir
$version = Get-PluginVersion -Raw $pluginRaw

# The closing-summary contract lives in the renderer; read it through the same dot-source guard
# the tests use, so this generator never keeps its own copy of the four blocks (#493).
$summaryScript = (Resolve-Path (Join-Path $PSScriptRoot 'Board-Summary.ps1')).Path
$prevGuard = $env:ABIOS_BOARDSUMMARY_DOTSOURCE
$env:ABIOS_BOARDSUMMARY_DOTSOURCE = '1'
try { . $summaryScript } finally { $env:ABIOS_BOARDSUMMARY_DOTSOURCE = $prevGuard }
$summaryPrompt = Format-ClosingSummaryPrompt -Blocks @(Get-ClosingSummaryBlocks)

# Match the README's own newline so the generated region does not read back as
# "stale" purely from CRLF-vs-LF (Format-CatalogTable emits LF).
$nl              = Get-DominantNewline -Text $readme
$table           = (Format-CatalogTable -Rows $catalog) -replace "`r?`n", $nl
$commandsContent = "$nl$table$nl"
$versionContent  = "v$version"

# Splice both marked regions. The command block sits on its own lines (newline
# padding); the version marker is inline, so its content is just the string.
$updated = Set-MarkedRegion -Text $readme  -Name 'commands' -Content $commandsContent
$updated = Set-MarkedRegion -Text $updated -Name 'version'  -Content $versionContent

# Which regions differ? Report per-region so the gate message is actionable.
$stale = @()
if ((Set-MarkedRegion -Text $readme -Name 'commands' -Content $commandsContent) -ne $readme) { $stale += 'command catalog' }
if ((Set-MarkedRegion -Text $readme -Name 'version'  -Content $versionContent)  -ne $readme) { $stale += 'version' }

# Every command file carries the closing-summary contract (#493). A file MISSING the region is
# an error, not a skip: a new command that never got the markers would otherwise ship with no
# closing contract at all, which is exactly the gap this replaces.
$commandPaths = @{}
$commandFiles = foreach ($cmdFile in (Get-ChildItem -Path $commandsDir -Filter '*.md' -File | Sort-Object Name)) {
    $commandPaths[$cmdFile.Name] = $cmdFile.FullName
    @{ Name = $cmdFile.Name; Text = [System.IO.File]::ReadAllText($cmdFile.FullName) }
}
$plan           = Get-CommandRegionPlan -Files @($commandFiles) -Prompt $summaryPrompt
$commandWrites  = @($plan.Writes)
$commandMissing = @($plan.Missing)
if ($commandMissing.Count) { $stale += "closing-summary region unusable in: $(($commandMissing.Name) -join ', ')" }
if ($commandWrites.Count)  { $stale += "closing summary in $($commandWrites.Count) command file(s)" }

if ($Check) {
    Write-Host "=== Docs check  ($([System.IO.Path]::GetFileName($ReadmePath)) + commands) ===" -ForegroundColor Cyan
    if ($stale.Count -eq 0) {
        Write-Host "  OK  derived regions are up to date (commands, version, closing summary)" -ForegroundColor Green
        exit 0
    }
    Write-Host "  FAIL  stale in: $($stale -join ', ')" -ForegroundColor Red
    foreach ($m in $commandMissing) { Write-Host "        $($m.Name): $($m.Reason)" -ForegroundColor DarkGray }
    if ($commandMissing.Count) {
        Write-Host "        A file with no region needs one added by hand:" -ForegroundColor DarkGray
        Write-Host "          <!-- BEGIN:closing-summary --><!-- END:closing-summary -->" -ForegroundColor DarkGray
    }
    Write-Host "        Then regenerate the docs and commit the result." -ForegroundColor DarkGray
    exit 1
}

# The markers are authored, not derived, so regenerating cannot repair them. Stop before writing
# ANYTHING: a half-applied run (README rewritten, command files not) is harder to reason about
# than one that changed nothing and said why.
if ($commandMissing.Count) {
    Write-Host "FAIL  closing-summary region unusable - nothing was written:" -ForegroundColor Red
    foreach ($m in $commandMissing) { Write-Host "        $($m.Name): $($m.Reason)" -ForegroundColor DarkGray }
    Write-Host "      A file with no region needs <!-- BEGIN:closing-summary --><!-- END:closing-summary --> added, then re-run." -ForegroundColor DarkGray
    exit 1
}

if ($stale.Count -eq 0) {
    Write-Host "Docs already up to date (commands, version, closing summary) - nothing to write." -ForegroundColor DarkGray
    exit 0
}

if ($DryRun) {
    Write-Host "DRY-RUN - would regenerate: $($stale -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Command catalog that would be written:" -ForegroundColor Cyan
    Write-Host $table
    Write-Host ""
    Write-Host "Version marker -> v$version" -ForegroundColor Cyan
    if ($commandWrites.Count) {
        Write-Host ""
        Write-Host "Closing summary would be refreshed in: $(($commandWrites.Name) -join ', ')" -ForegroundColor Cyan
    }
    exit 0
}

# $updated already carries both README regions spliced; if it is byte-identical the README is
# current and must not be rewritten just because a command file drifted.
if ($updated -ne $readme) { [System.IO.File]::WriteAllText($ReadmePath, $updated, $Utf8NoBom) }
foreach ($w in $commandWrites) { [System.IO.File]::WriteAllText($commandPaths[$w.Name], $w.Text, $Utf8NoBom) }

Write-Host "OK  regenerated: $($stale -join ', ')" -ForegroundColor Green
Write-Host "    ($($catalog.Count) commands from frontmatter; version v$version from plugin.json)" -ForegroundColor DarkGray
