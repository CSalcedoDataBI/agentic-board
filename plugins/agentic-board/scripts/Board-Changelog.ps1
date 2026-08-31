<#
.SYNOPSIS
    Generate a Keep-a-Changelog block from closed board items (M4.2).

.DESCRIPTION
    GitHub Projects best practice: the board is the single source of truth for
    what shipped. This script turns the board's Done issues into a CHANGELOG
    version block, grouped into Keep-a-Changelog sections by the board's Type
    field (falling back to labels):

      Feature                  -> ### Added
      Bug                      -> ### Fixed
      Docs / Refactor / Chore  -> ### Changed
      (no Type) -> infer from labels: bug -> Fixed; docs/refactor/chore ->
                   Changed; otherwise Added.

    Which issues are included (both filters apply, so already-shipped work is
    never re-listed):
      1. closedAt >= -Since  (default: the date of the most recent CHANGELOG
         entry, so only work since the last release is considered), and
      2. the issue number is NOT already cited as (#<n>) anywhere in the
         existing CHANGELOG.

    Prints the block to stdout. With -Write it is inserted at the top of the
    CHANGELOG (just under the "# Changelog" header), ready to commit.

    Linked PRs / merge state are not needed here - a Done+closed issue is what
    "shipped" means on this board.

.PARAMETER Owner
    GitHub user that owns the board. Default CSalcedoDataBI.

.PARAMETER ProjectNum
    Projects v2 number. Default 13.

.PARAMETER Repo
    owner/name - only issues from this repo are included. Default: origin.

.PARAMETER Version
    Version string for the header. Default: version from the plugin.json under
    plugins/*/.claude-plugin/, else 0.0.0.

.PARAMETER Date
    ISO date for the header. Default: today.

.PARAMETER Since
    Only issues closed on/after this ISO date. Default: the date of the most
    recent existing CHANGELOG entry (## [x] - YYYY-MM-DD).

.PARAMETER Write
    Insert the block at the top of the CHANGELOG instead of only printing it.

.PARAMETER ChangelogPath
    Path to the changelog file. Default: CHANGELOG.md in the cwd.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Board-Changelog.ps1 -ProjectNum 13
    .\Board-Changelog.ps1 -ProjectNum 13 -Version 0.11.0 -Write
    .\Board-Changelog.ps1 -ProjectNum 13 -Since 2026-06-01
#>
[CmdletBinding()]
param(
    [string]$Owner         = "CSalcedoDataBI",
    [int]   $ProjectNum    = 13,
    [string]$Repo          = "",
    [string]$Version       = "",
    [string]$Date          = "",
    [string]$Since         = "",
    [switch]$Write,
    [string]$ChangelogPath = "CHANGELOG.md",
    [string]$TokenVar      = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ── Pure CHANGELOG-write helpers (#324) ───────────────────────────────────────
# The fold must COMPOSE with a hand-written `## [Unreleased]` block (standard Keep-a-Changelog
# practice). The old -Write inserted the generated block right under `# Changelog`, ABOVE any
# `[Unreleased]`, which stranded the maintainer's curated entries under an orphan [Unreleased]
# BELOW the very version they belonged to. When an [Unreleased] exists we now RENAME it to the
# dated version header and merge the board-derived entries INTO its sections instead.

# Merge board-derived section lines into an existing [Unreleased] body, rebuilt under a dated
# version header. Preserves the maintainer's sections + order and any section the board has no
# opinion about (e.g. a hand-written `### Security`); board lines are appended AFTER the
# hand-written ones per section (no dedup needed — the generator already excludes any issue
# already cited in the file). Pure.
function Merge-UnreleasedBody {
    param([string]$Body, $Sections, [string]$Version, [string]$Date)
    $map = [ordered]@{}          # section name -> lines ('' collects any preamble before the first ###)
    $cur = ''
    foreach ($line in ($Body -split "`r?`n")) {
        $h = [regex]::Match($line, '^###[ \t]+(.+?)[ \t]*$')
        if ($h.Success) { $cur = $h.Groups[1].Value; if (-not $map.Contains($cur)) { $map[$cur] = @() } }
        else            { if (-not $map.Contains($cur)) { $map[$cur] = @() }; $map[$cur] += $line }
    }
    foreach ($sec in $Sections.Keys) {
        $blines = @($Sections[$sec])
        if ($blines.Count -eq 0) { continue }
        if (-not $map.Contains($sec)) { $map[$sec] = @() }
        $map[$sec] += ($blines | Sort-Object)
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## [$Version] - $Date")
    if ($map.Contains('') -and ((@($map['']) -join '').Trim())) {
        foreach ($l in $map['']) { if ($l.Trim()) { [void]$sb.AppendLine($l) } }
    }
    foreach ($sec in $map.Keys) {
        if ($sec -eq '') { continue }
        $lines = @($map[$sec])
        $s = 0; $e = $lines.Count - 1                       # trim leading/trailing blank lines per section
        while ($s -le $e -and -not $lines[$s].Trim()) { $s++ }
        while ($e -ge $s -and -not $lines[$e].Trim()) { $e-- }
        if ($s -gt $e) { continue }
        [void]$sb.AppendLine("### $sec")
        foreach ($l in $lines[$s..$e]) { [void]$sb.AppendLine($l) }
    }
    return $sb.ToString().TrimEnd()
}

# Decide how the generated block lands in the existing CHANGELOG text. Returns
# { Changed; Text; Message }. Three cases:
#   1. an [Unreleased] section exists -> rename it to [Version] and merge board entries in;
#   2. no [Unreleased] but the block has entries -> insert under the `# Changelog` header (old path);
#   3. no [Unreleased] and nothing new -> no-op (Changed=$false).
# Pure -> unit-testable via the dot-source guard below.
function Update-ChangelogText {
    param([string]$Original, [string]$Block, $Sections, [string]$Version, [string]$Date)
    $unrel = [regex]::Match($Original, '(?ms)^##[ \t]*\[Unreleased\][ \t]*\r?\n(.*?)(?=^##[ \t]*\[|\z)')
    if ($unrel.Success) {
        $merged = Merge-UnreleasedBody -Body $unrel.Groups[1].Value -Sections $Sections -Version $Version -Date $Date
        $tail   = $Original.Substring($unrel.Index + $unrel.Length) -replace '^(\s*\r?\n)+', ''
        $newText = $Original.Substring(0, $unrel.Index) + $merged + "`n`n" + $tail
        $n = 0; foreach ($k in $Sections.Keys) { $n += @($Sections[$k]).Count }
        return [pscustomobject]@{ Changed = $true; Text = $newText
            Message = ("[Unreleased] renombrado a [{0}] - {1}; {2} entrada(s) del board fusionada(s)." -f $Version, $Date, $n) }
    }
    if ($Block -match '(?m)^###') {
        if ($Original -match '(?s)^(#\s+Changelog\s*\r?\n)(\r?\n)?(.*)$') {
            $newText = $Matches[1] + "`n" + $Block + "`n`n" + $Matches[3]
        } else {
            $newText = $Block + "`n`n" + $Original
        }
        return [pscustomobject]@{ Changed = $true; Text = $newText
            Message = ("bloque [{0}] insertado bajo el encabezado." -f $Version) }
    }
    return [pscustomobject]@{ Changed = $false; Text = $Original
        Message = "nada que escribir (sin [Unreleased] y sin issues nuevos)." }
}

# Pick THE plugin.json to read the version from, deterministically (#319). The old code did a
# RECURSIVE `Get-ChildItem -Recurse -Filter plugin.json | ... -First 1` — a coin toss weighted by
# directory order that picked a STALE copy inside an ignored `.claude/worktrees/` tree (the very
# layout `/board work` creates) and stamped the changelog with a version that already shipped, then
# `-Write` inserted a duplicate block that read as the version going backwards. A silent pick is how
# the bug works, so given the already-filtered candidate list: none -> $null; exactly one -> it; more
# than one -> THROW with the list rather than guess. Pure. #303 class (answer confidently or fail,
# never guess).
function Select-PluginVersionFile {
    param([string[]]$Candidates)      # absolute paths, already existence- and ignore-filtered
    $u = @($Candidates | Where-Object { $_ } | Sort-Object -Unique)
    if ($u.Count -eq 0) { return $null }
    if ($u.Count -gt 1) {
        throw "Version ambigua: varios plugin.json candidatos (resuelve con -Version):`n  $($u -join "`n  ")"
    }
    return $u[0]
}

# Dot-source guard: with $env:ABIOS_CHANGELOG_DOTSOURCE set, return after defining the pure
# helpers WITHOUT reading gh/the board — lets the tests exercise Update-ChangelogText directly.
if ($env:ABIOS_CHANGELOG_DOTSOURCE) { return }

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# gh must fail closed on the board read that feeds the CHANGELOG write (#303/#316): -Graphql throws
# on an exit-0 errors[] body too, so a read failure is named accurately instead of hitting the
# generic "revisa cuenta / scope" fallback the null-id guard prints.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# ── Resolve repo (filter issues to it) ────────────────────────────────────────
if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "No pude derivar el repo del origin - pasa -Repo owner/name." }

# ── Existing CHANGELOG: cited issue numbers + last entry date ─────────────────
$alreadyCited = @{}
$lastEntryDate = $null
if (Test-Path $ChangelogPath) {
    $clText = Get-Content $ChangelogPath -Raw
    foreach ($m in [regex]::Matches($clText, '#(\d+)')) { $alreadyCited[[int]$m.Groups[1].Value] = $true }
    $dm = [regex]::Match($clText, '##\s*\[[^\]]+\]\s*-\s*(\d{4}-\d{2}-\d{2})')
    if ($dm.Success) { $lastEntryDate = $dm.Groups[1].Value }
}

if (-not $Since) { $Since = $lastEntryDate }
# ISO dates only; parse invariant so a dd/MM machine culture doesn't choke.
$sinceDt = if ($Since) {
    [datetime]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal)
} else { [datetime]::MinValue }

# ── Defaults for Version / Date ───────────────────────────────────────────────
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $Version) {
    # Resolve the plugin root deterministically, never by a recursive sweep (#319).
    $candidates = @()
    # 1. Prefer the plugin.json this script SHIPS beside — it is the one versioning this release.
    $primary = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath '.claude-plugin' | Join-Path -ChildPath 'plugin.json'
    if (Test-Path $primary) {
        $candidates += (Resolve-Path -LiteralPath $primary).Path
    } else {
        # 2. Fallback: ask git for the repo root and look ONLY at plugins/*/.claude-plugin/plugin.json,
        #    excluding any path git ignores (the stale worktree copy that triggered this is ignored).
        $root = (git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $root) {
            $pluginsDir = Join-Path $root 'plugins'
            if (Test-Path $pluginsDir) {
                foreach ($dir in (Get-ChildItem -Path $pluginsDir -Directory -ErrorAction SilentlyContinue)) {
                    $pj = Join-Path $dir.FullName '.claude-plugin' | Join-Path -ChildPath 'plugin.json'
                    if (-not (Test-Path $pj)) { continue }
                    git check-ignore -q -- "$pj" 2>$null
                    if ($LASTEXITCODE -ne 0) { $candidates += (Resolve-Path -LiteralPath $pj).Path }   # exit!=0 => NOT ignored
                }
            }
        }
    }
    $pjPath = Select-PluginVersionFile -Candidates $candidates
    if ($pjPath) {
        $vm = [regex]::Match((Get-Content $pjPath -Raw), '"version"\s*:\s*"([^"]+)"')
        if ($vm.Success) { $Version = $vm.Groups[1].Value }
    }
    if (-not $Version) { $Version = "0.0.0" }
}

# ── Read board items, paginated (issue #246: items(first:100) alone skipped issues
#    on boards >100 items, so the changelog silently missed recent entries) ───────
$nodes = @(); $cursor = $null
do {
    # Cursor as a GraphQL variable (-f cursor=), never interpolated as after: "$cursor": embedded
    # double-quotes in a native gh.exe arg are not escaped, so gh saw the base64 cursor unquoted and
    # its `==` padding parsed as bare tokens -> parse error on every board >100 items (#329).
    $q = @"
query(`$owner:String!, `$num:Int!, `$cursor:String) {
  user(login:`$owner) {
    projectV2(number:`$num) {
      id
      items(first:100, after:`$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          fieldValues(first:20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
          content {
            __typename
            ... on Issue {
              number title state closedAt url
              labels(first:15) { nodes { name } }
            }
          }
        }
      }
    }
  }
}
"@
    $ghArgs = @('api','graphql','-f',"query=$q",'-F',"owner=$Owner",'-F',"num=$ProjectNum")
    if ($cursor) { $ghArgs += @('-f',"cursor=$cursor") }
    $data = Invoke-Gh -GhArgs $ghArgs -What "leer los items del board #$ProjectNum de $Owner" -Graphql
    $pv = $data.data.user.projectV2
    if (-not $pv.id) {
        throw "No pude resolver el board #$ProjectNum de $Owner (revisa cuenta / scope 'project')."
    }
    $nodes += @($pv.items.nodes)
    $cursor = $pv.items.pageInfo.endCursor
    $more   = $pv.items.pageInfo.hasNextPage
} while ($more)

# ── Select + bucket ───────────────────────────────────────────────────────────
$sections = [ordered]@{ Added = @(); Changed = @(); Fixed = @() }

function Resolve-Section($type, $labels) {
    switch ($type) {
        'Feature'  { return 'Added' }
        'Bug'      { return 'Fixed' }
        'Docs'     { return 'Changed' }
        'Refactor' { return 'Changed' }
        'Chore'    { return 'Changed' }
    }
    if ($labels -contains 'bug')                                              { return 'Fixed' }
    if ($labels -contains 'docs' -or $labels -contains 'refactor' -or $labels -contains 'chore') { return 'Changed' }
    return 'Added'
}

$skippedRepo = 0; $skippedCited = 0; $skippedOld = 0; $included = 0
foreach ($n in $nodes) {
    $c = $n.content
    if ($c.__typename -ne 'Issue') { continue }
    if ($c.state -ne 'CLOSED') { continue }
    if ($c.url -notlike "*/$Repo/issues/*") { $skippedRepo++; continue }
    if ($alreadyCited.ContainsKey([int]$c.number)) { $skippedCited++; continue }
    if ($c.closedAt) {
        # ConvertFrom-Json already coerces the ISO string to [datetime]; only
        # parse (invariant) if it arrived as a string.
        $closed = if ($c.closedAt -is [datetime]) { $c.closedAt }
                  else { [datetime]::Parse([string]$c.closedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        if ($closed -lt $sinceDt) { $skippedOld++; continue }
    }

    $type   = ($n.fieldValues.nodes | Where-Object { $_.field.name -eq 'Type' }).name
    $labels = @($c.labels.nodes.name | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
    $sec    = Resolve-Section $type $labels
    $sections[$sec] += "- **$($c.title)** (#$($c.number))"
    $included++
}

# ── Build the block ───────────────────────────────────────────────────────────
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("## [$Version] - $Date")
$any = $false
foreach ($secName in $sections.Keys) {
    $lines = $sections[$secName]
    if ($lines.Count -eq 0) { continue }
    $any = $true
    [void]$sb.AppendLine("### $secName")
    foreach ($l in ($lines | Sort-Object)) { [void]$sb.AppendLine($l) }
}
$block = $sb.ToString().TrimEnd()

Write-Host "=== Board-Changelog  $Repo  board #$ProjectNum ===" -ForegroundColor Cyan
Write-Host ("  Since: {0}  |  incluidos: {1}  |  omitidos: {2} otro-repo, {3} ya-citados, {4} anteriores" -f `
    ($(if ($Since) { $Since } else { "(todo)" })), $included, $skippedRepo, $skippedCited, $skippedOld) -ForegroundColor DarkGray
Write-Host ""

if ($any) {
    Write-Host $block
    Write-Host ""
} else {
    # No new board entries. In print-only mode there is nothing to do; but under -Write a
    # hand-written [Unreleased] must still be RENAMED to this version (a release can ship with
    # only curated prose and no newly-Done issues), so do NOT exit before the write below.
    Write-Host "  Sin issues Done nuevos para changelog (nada desde $Since que no este ya citado)." -ForegroundColor Green
    if (-not $Write) { exit 0 }
}

# ── Optionally write into the CHANGELOG ───────────────────────────────────────
if ($Write) {
    if (-not (Test-Path $ChangelogPath)) { throw "No existe $ChangelogPath - no puedo insertar." }
    $orig   = Get-Content $ChangelogPath -Raw
    $result = Update-ChangelogText -Original $orig -Block $block -Sections $sections -Version $Version -Date $Date
    if ($result.Changed) {
        Set-Content -Path $ChangelogPath -Value $result.Text -NoNewline
        Write-Host "OK  $($result.Message) (revisa y commitea)." -ForegroundColor Green
    } else {
        Write-Host "  $($result.Message)" -ForegroundColor DarkGray
    }
}
