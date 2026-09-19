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
                   Changed; enhancement/feature -> Added; otherwise the issue is
                   NOT included and is listed for you to place (no default heading).

    Which issues are included. "Closed since the last release" is NOT the same question as "this
    release fixed it" (#676): the fold once announced #661 - closed as a duplicate of a fix a month
    old - as a new feature of the release. All of these must hold, and every issue left out is
    reported with its reason, so nothing disappears silently:
      1. it is closed and belongs to -Repo;
      2. it was NOT closed as "not planned" (a duplicate or a won't-fix is never release content);
      3. it was closed BY a merged pull request (closedByPullRequestsReferences; when that list is
         truncated and the merged PR is not among those read, the fact CANNOT BE ESTABLISHED and the
         issue is listed for you instead of being judged on a partial list), and that PR was
         merged on/after -Since (default: the date of the most recent CHANGELOG entry). An issue
         closed by hand, or by a commit with no PR, is listed for you to add by hand;
      4. the issue number is not already cited in the existing CHANGELOG - as `(#<n>)` OR inside a
         range such as `#423-#430`, which the old check missed for every number in the middle;
      5. it has a Type (or label) that says which heading it belongs under. There is no default
         heading: an unclassified issue is listed for you to place, never filed under `### Added`.

    This repo hand-curates its [Unreleased] block; this generator only proposes candidates and must
    not lie about them.

    Prints the block to stdout. With -Write it is inserted at the top of the
    CHANGELOG (just under the "# Changelog" header), ready to commit.

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
    Only issues whose closing PR was merged on/after this ISO date. Default: the
    date of the most recent existing CHANGELOG entry (## [x] - YYYY-MM-DD).

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

# ── What belongs in this release (#676) ────────────────────────────────────────

# Every issue number a CHANGELOG cites: single `#n` AND ranges written `#a-#b` / `#a–#b` (hyphen,
# en dash, em dash, or `..`), expanded. The old check collected single numbers only, so the whole
# middle of a cited range - #424..#429 of `#423–#430` - was invisible and got folded in again. A
# range needs a `#` on both ends (`#12 - 30 files` is not one) and is capped at 200 numbers so a
# typo cannot mark half the tracker as shipped. Pure. Returns int[].
function Get-CitedIssueNumbers {
    param([string]$Text)
    $set = New-Object System.Collections.Generic.HashSet[int]
    if (-not $Text) { return @() }
    foreach ($m in [regex]::Matches($Text, '#(\d+)')) { [void]$set.Add([int]$m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Text, '#(\d+)[ \t]*(?:-|\u2013|\u2014|\.\.\.?|\u2026)[ \t]*#(\d+)')) {
        $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
        if ($b -gt $a -and ($b - $a) -le 200) { for ($i = $a; $i -le $b; $i++) { [void]$set.Add($i) } }
    }
    return @($set)
}

# Which heading does this issue go under? $null when neither the Type nor a label says - there is NO
# default heading: the old fallback filed every unclassified issue under `### Added`, including a
# bug. Pure.
function Resolve-ChangelogSection {
    param($Type, $Labels)
    switch ("$Type") {
        'Feature'  { return 'Added' }
        'Bug'      { return 'Fixed' }
        'Docs'     { return 'Changed' }
        'Refactor' { return 'Changed' }
        'Chore'    { return 'Changed' }
    }
    $l = @($Labels | Where-Object { $_ } | ForEach-Object { "$_".ToLower() })
    if ($l -contains 'bug')                                               { return 'Fixed' }
    if ($l -contains 'docs' -or $l -contains 'refactor' -or $l -contains 'chore') { return 'Changed' }
    if ($l -contains 'enhancement' -or $l -contains 'feature')            { return 'Added' }
    return $null
}

# Does this CLOSED issue belong in the release being folded? Pure.
#   $Issue: { state; stateReason; closedByPullRequestsReferences = { totalCount; pageInfo = { hasNextPage };
#             nodes = @({ number; state; merged; mergedAt }) } }
# Returns @{ include; reason } - reason is a short code the report prints:
#   not-closed | not-planned | unknown-prs | no-merged-pr | pr-before-release | ok
# `unknown-prs`: the closing-PR connection is a page (first:5), and "no merged PR" or "merged before the
# release" are claims about ALL of them. If the page is truncated - or the response does not say
# whether it is - and no merged PR of this release is among the ones read, the answer is "cannot
# establish", never a guess (a busy issue must not be misjudged as unfixed or as already shipped).
# A merged PR of this release that WAS read is enough to include: that fact is established.
function Test-IssueInRelease {
    param($Issue, [datetime]$SinceDt = [datetime]::MinValue)
    if ("$($Issue.state)" -ne 'CLOSED') { return @{ include = $false; reason = 'not-closed' } }
    $sr = "$($Issue.stateReason)".ToUpperInvariant()
    if ($sr -eq 'NOT_PLANNED' -or $sr -eq 'DUPLICATE') { return @{ include = $false; reason = 'not-planned' } }

    $conn  = $Issue.closedByPullRequestsReferences
    $nodes = @($conn.nodes | Where-Object { $_ })
    $prs   = @($nodes | Where-Object { ("$($_.state)" -eq 'MERGED') -or ($_.merged -eq $true) })

    foreach ($pr in $prs) {
        if (-not $pr.mergedAt) { continue }
        $merged = if ($pr.mergedAt -is [datetime]) { $pr.mergedAt }
                  else { [datetime]::Parse([string]$pr.mergedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        if ($merged -ge $SinceDt) { return @{ include = $true; reason = 'ok' } }
    }

    # Nothing of this release was read. Was the whole list read?
    $pageInfo = if ($conn -and ($conn.PSObject.Properties.Name -contains 'pageInfo')) { $conn.pageInfo } else { $null }
    # Complete ONLY when the response says so explicitly: absent pageInfo / absent hasNextPage / $null
    # all read as "cannot tell", i.e. not complete.
    $hasNext  = -not ($pageInfo -and $pageInfo.hasNextPage -eq $false)
    $total = if ($conn -and ($conn.PSObject.Properties.Name -contains 'totalCount') -and $null -ne $conn.totalCount) { [int]$conn.totalCount } else { -1 }
    if ($hasNext -or ($total -ge 0 -and $total -gt $nodes.Count)) { return @{ include = $false; reason = 'unknown-prs' } }

    if ($prs.Count -eq 0) { return @{ include = $false; reason = 'no-merged-pr' } }
    return @{ include = $false; reason = 'pr-before-release' }
}

# The selection loop, extracted so it can be tested without a board. $Nodes are the project items as
# the GraphQL read returns them. Returns @{ Sections; Included; Skipped } where every issue that was
# NOT folded appears in Skipped with its reason. Pure.
function Select-ChangelogItems {
    param($Nodes, [string]$Repo, $AlreadyCited, [datetime]$SinceDt = [datetime]::MinValue)
    $sections = [ordered]@{ Added = @(); Changed = @(); Fixed = @() }
    $skipped = @(); $included = 0
    foreach ($n in @($Nodes)) {
        $c = $n.content
        if ($c.__typename -ne 'Issue') { continue }
        if ($c.state -ne 'CLOSED') { continue }
        $num = [int]$c.number
        if ($c.url -notlike "*/$Repo/issues/*") { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = 'other-repo' }; continue }

        # Closed before the last release: history, not a candidate. Counted, never listed - a board's
        # whole closed backlog is not a to-do list for this release.
        if ($c.closedAt) {
            $closed = if ($c.closedAt -is [datetime]) { $c.closedAt }
                      else { [datetime]::Parse([string]$c.closedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
            if ($closed -lt $SinceDt) { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = 'older' }; continue }
        }
        $verdict = Test-IssueInRelease -Issue $c -SinceDt $SinceDt
        if ($verdict.reason -eq 'not-planned') { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = 'not-planned' }; continue }
        if ($AlreadyCited.ContainsKey($num))   { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = 'already-cited' }; continue }
        if (-not $verdict.include)             { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = $verdict.reason }; continue }

        $type   = Get-ItemTypeName $n.fieldValues.nodes   # vocabulary-aware: 'Type', 'Task Type', 'Tipo' (#671)
        $labels = @($c.labels.nodes.name | Where-Object { $_ })
        $sec    = Resolve-ChangelogSection -Type $type -Labels $labels
        if (-not $sec) { $skipped += [pscustomobject]@{ number = $num; title = "$($c.title)"; reason = 'unclassified' }; continue }
        $sections[$sec] += "- **$($c.title)** (#$num)"
        $included++
    }
    return [pscustomobject]@{ Sections = $sections; Included = $included; Skipped = @($skipped) }
}


# The field names come from the shared vocabulary (#671): the board's type field is 'Type' on older
# boards, 'Task Type' on ones the English preset made (GitHub reserves 'Type'), 'Tipo' in Spanish.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')

# The changelog TYPE of one board item, read from its single-select field values whatever the board
# calls the type field, and normalised to the canonical option name (a Spanish board's 'Funcionalidad'
# is 'Feature'). $null when the item has no type. Pure (#671).
function Get-ItemTypeName {
    param([object[]]$FieldValueNodes)
    foreach ($name in (Get-BoardFieldNames 'Type')) {
        $fv = @($FieldValueNodes) | Where-Object { $_ -and $_.field.name -eq $name } | Select-Object -First 1
        if ($fv -and $fv.name) { return (Get-CanonicalSynonym 'Type' $fv.name) }
    }
    return $null
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
    foreach ($num in (Get-CitedIssueNumbers -Text $clText)) { $alreadyCited[[int]$num] = $true }
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
              number title state stateReason closedAt url
              labels(first:15) { nodes { name } }
              closedByPullRequestsReferences(first:5, includeClosedPrs:true) { totalCount pageInfo { hasNextPage } nodes { number state merged mergedAt } }
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
$sel      = Select-ChangelogItems -Nodes $nodes -Repo $Repo -AlreadyCited $alreadyCited -SinceDt $sinceDt
$sections = $sel.Sections
$included = $sel.Included
$skipCount = @{}
foreach ($s in $sel.Skipped) { $skipCount[$s.reason] = 1 + [int]$skipCount[$s.reason] }
function Get-SkipCount([string]$k) { [int]$skipCount[$k] }
$skippedRepo = Get-SkipCount 'other-repo'; $skippedCited = Get-SkipCount 'already-cited'; $skippedOld = Get-SkipCount 'older'

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
Write-Host ("  Since: {0}  |  incluidos: {1}  |  omitidos: {2} otro-repo, {3} ya-citados (incl. rangos), {4} anteriores, {5} no-planeados" -f `
    ($(if ($Since) { $Since } else { "(todo)" })), $included, $skippedRepo, $skippedCited, $skippedOld, (Get-SkipCount 'not-planned')) -ForegroundColor DarkGray
# Nothing is dropped silently: what a human may want to place by hand is named, with the reason.
$review = @($sel.Skipped | Where-Object { $_.reason -in @('no-merged-pr', 'pr-before-release', 'unknown-prs', 'unclassified') })
if ($review.Count -gt 0) {
    Write-Host "  Cerrados pero NO incluidos (revisa a mano si corresponden a este release):" -ForegroundColor Yellow
    foreach ($r in $review) {
        $why = switch ($r.reason) {
            'no-merged-pr'      { 'no lo cerro ningun PR mergeado' }
            'pr-before-release' { 'su PR se mergeo antes de este release' }
            'unknown-prs'       { 'tiene mas PRs de los que se leyeron: no se pudo establecer cual lo cerro' }
            'unclassified'      { 'sin Type ni label: no se en que seccion va' }
        }
        Write-Host ("    #{0}  {1}  - {2}" -f $r.number, $r.title, $why) -ForegroundColor DarkYellow
    }
}
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
