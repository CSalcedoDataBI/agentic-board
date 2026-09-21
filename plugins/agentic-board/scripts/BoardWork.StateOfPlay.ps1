# BoardWork.StateOfPlay.ps1 - the "state of play" that /board work prints BEFORE its pending list (#660).
#
# Asking "what is in progress and what is pending?" used to be answered by the board query alone.
# But the board does not know about a run marker left `active`, an epic whose sub-issues are all
# closed, a worktree whose branch already merged, an open issue nobody put on the board, or a
# CHANGELOG [Unreleased] block waiting for a release. A clean board therefore read as "nothing in
# flight" while five real things were open: the board reporting its own view as the state of the work.
#
# Every source below is read from the thing that EXECUTES it (the marker file, `git worktree`, live
# PRs, the issue list vs the board, the default branch's CHANGELOG vs its last tag), never from a
# cached or self-reported summary. Each finding is an OFFER: this file only reads. What happens on a
# yes stays behind the confirmation of the verb that owns the disposition (see verbs-work.md).
#
# Two rules the whole file keeps, because they are the ones the board itself broke:
#   * A source that could not be read is a finding of its own ('unknown'), never a silent empty
#     result: "I could not tell" must not print as "all clear" (#278/#303/#484).
#   * Function definitions only. Pure at load (no gh, no git, no output) so Board-Work.ps1's
#     dot-source guard and the tests see the same surface. The classifiers are PURE; the
#     Read-State* functions are the only ones that touch gh/git/disk.
#
# Finding shape: { Source; Group; Text; Offer }.
#   Group: inflight | stale | offboard | due | unknown | skipped
#   'skipped' = a source that does not apply here (say so, but it does not make the repo "dirty").

# ------------------------------------------------------------------------------ pure helpers

function New-StateFinding {
    param([string]$Source, [string]$Group, [string]$Text, [string]$Offer = '')
    [pscustomobject]@{ Source = $Source; Group = $Group; Text = $Text; Offer = $Offer }
}

# "#1 #2 #3" for a list of numbers, capped so a 60-issue backlog does not bury the rest of the
# picture. The cap is SAID ("y N mas"), never silent.
function Format-StateNumberList {
    param([int[]]$Numbers, [int]$Max = 12)
    $n = @($Numbers)
    if ($n.Count -eq 0) { return '' }
    $shown = @($n | Select-Object -First $Max | ForEach-Object { "#$_" }) -join ' '
    if ($n.Count -gt $Max) { $shown += " y $($n.Count - $Max) mas" }
    return $shown
}

# Board items that are In Progress / In Review. Pure over the items Get-BoardItems returns. A draft
# note has no issue for anyone to be working on, so it never counts as in flight.
function Get-BoardInFlightFindings {
    param([object[]]$Items = @())
    $active = @($Items | Where-Object {
        $_ -and $_.status -and $_.content -and $_.content.type -ne 'DraftIssue' -and $_.content.number -and
        (@('In Progress', 'In Review') -contains (Get-CanonicalOptionName 'Status' $_.status))
    })
    if ($active.Count -eq 0) { return @() }
    $nums = @($active | ForEach-Object { [int]$_.content.number } | Sort-Object -Unique)
    @(New-StateFinding -Source 'board' -Group 'inflight' `
        -Text ("El board tiene {0} item(s) en progreso o en review: {1}." -f $nums.Count, (Format-StateNumberList $nums)))
}

# Open PRs of the repo. Pure over `gh pr list` rows. A capped read is flagged: "N PRs" off a list
# that hit its cap is a floor, not a count.
function Get-OpenPrFindings {
    param([object[]]$Prs = @(), [int]$Cap = 100)
    $rows = @($Prs | Where-Object { $_ })
    if ($rows.Count -eq 0) { return @() }
    $plus = if ($rows.Count -ge $Cap) { '+' } else { '' }
    $desc = @($rows | Sort-Object { [int]$_.number } | Select-Object -First 8 | ForEach-Object {
        $draft = if ($_.isDraft) { ' [borrador]' } else { '' }
        "PR #$($_.number)$draft (rama $($_.headRefName))"
    }) -join '; '
    if ($rows.Count -gt 8) { $desc += "; y $($rows.Count - 8) mas" }
    @(New-StateFinding -Source 'pr' -Group 'inflight' -Text ("{0}{1} PR(s) abiertos: {2}." -f $rows.Count, $plus, $desc))
}

# The autonomous-run marker (.agentic-board/active-run.json). Pure. $OpenNumbers is the set of
# OPEN issue numbers of the repo; $Verified says whether that set was read completely - without it
# nothing may be concluded about the queue.
#   * no marker, or a run already closed  -> nothing (a closed run is not open work)
#   * active, epic gone from the open set, or every queued issue gone from it -> STALE
#   * active with queue members still open -> IN FLIGHT
#   * active and the open set is unverified -> UNKNOWN (never guess)
function Get-RunMarkerFinding {
    param($Marker, [int[]]$OpenNumbers = @(), [bool]$Verified = $true)
    if (-not $Marker) { return $null }
    if ("$($Marker.status)" -ne 'active') { return $null }

    $epic  = [int]$Marker.epic
    $queue = @(@($Marker.queue) | Where-Object { $null -ne $_ -and "$_" -match '^\d+$' } | ForEach-Object { [int]$_ })
    $when  = if ($Marker.updated) { " (ultima actualizacion $("$($Marker.updated)".Substring(0, [math]::Min(10, "$($Marker.updated)".Length))))" } else { '' }

    if (-not $Verified) {
        return New-StateFinding -Source 'run' -Group 'unknown' `
            -Text "Hay una corrida autonoma marcada activa sobre el epic #$epic y no pude comprobar si su cola sigue abierta."
    }

    $open       = @($OpenNumbers)
    $epicOpen   = ($open -contains $epic)
    $stillOpen  = @($queue | Where-Object { $open -contains $_ })
    $closedCnt  = $queue.Count - $stillOpen.Count

    if (-not $epicOpen -and $stillOpen.Count -gt 0) {
        # The epic was closed but the run's own queue still has open issues: that is not a run to
        # close on the tool's say-so, it is a disagreement the user should see (no offer attached).
        return New-StateFinding -Source 'run' -Group 'inflight' `
            -Text ("Corrida autonoma activa cuyo epic #{0} ya esta cerrado, pero de su cola siguen abiertos {1}{2}." -f $epic, (Format-StateNumberList $stillOpen), $when)
    }
    if (-not $epicOpen) {
        return New-StateFinding -Source 'run' -Group 'stale' `
            -Text "Una corrida autonoma sigue marcada como activa sobre el epic #$epic, pero ese epic ya esta cerrado$when." `
            -Offer 'cerrar esa corrida'
    }
    if ($queue.Count -gt 0 -and $stillOpen.Count -eq 0) {
        return New-StateFinding -Source 'run' -Group 'stale' `
            -Text ("Una corrida autonoma sigue marcada como activa sobre el epic #{0}, pero toda su cola ({1}) ya esta cerrada{2}." -f $epic, (Format-StateNumberList $queue), $when) `
            -Offer 'cerrar esa corrida'
    }
    if ($queue.Count -eq 0) {
        return New-StateFinding -Source 'run' -Group 'inflight' `
            -Text "Corrida autonoma activa sobre el epic #$epic (sin cola declarada)$when."
    }
    New-StateFinding -Source 'run' -Group 'inflight' `
        -Text ("Corrida autonoma activa sobre el epic #{0}: {1} de {2} de su cola cerrada, siguen abiertos {3}{4}." -f $epic, $closedCnt, $queue.Count, (Format-StateNumberList $stillOpen), $when)
}

# Open issues that ARE epics (they have sub-issues) with every sub-issue closed. Pure over rows of
# { number; title; subIssuesSummary { total; completed } }. total = 0 is not an epic.
function Get-FinishedEpicFindings {
    param([object[]]$OpenIssues = @())
    $done = @($OpenIssues | Where-Object {
        $_ -and $_.subIssuesSummary -and [int]$_.subIssuesSummary.total -gt 0 -and
        [int]$_.subIssuesSummary.completed -ge [int]$_.subIssuesSummary.total
    } | Sort-Object { [int]$_.number })
    foreach ($e in $done) {
        New-StateFinding -Source 'epic' -Group 'stale' `
            -Text ("El epic #{0} ('{1}') sigue abierto con sus {2} sub-issue(s) cerrados." -f $e.number, $e.title, $e.subIssuesSummary.total) `
            -Offer "cerrar el epic #$($e.number)"
    }
}

# Open issues of the repo that are not on the board at all. Pure. The comparison is only honest when:
#   * the open-issue read was COMPLETE (the caller passes $OpenVerified), and
#   * the board read was complete ($BoardTruncated = $false), and
#   * the board actually tracks this repo (at least one issue of it) - otherwise it is another
#     project's board and "not on it" means nothing.
# Anything else returns 'unknown' or 'skipped' rather than a confident list or a confident nothing.
function Get-OffBoardFindings {
    param(
        [object[]]$OpenIssues = @(), [object[]]$Items = @(), [string]$Repo,
        [bool]$OpenVerified = $true, [bool]$BoardTruncated = $false
    )
    if (-not $OpenVerified) {
        return @(New-StateFinding -Source 'offboard' -Group 'unknown' -Text 'No pude leer los issues abiertos del repo, asi que no se cuales faltan en el board.')
    }
    $mine = @($Items | Where-Object { $_ -and $_.content -and $_.content.number -and $_.content.type -ne 'DraftIssue' -and
                                       ((Get-ItemRepoName $_) -ieq $Repo) })
    if ($BoardTruncated) {
        return @(New-StateFinding -Source 'offboard' -Group 'unknown' -Text 'La lectura del board se corto, asi que no puedo decir que issues abiertos faltan en el.')
    }
    # Another project's board is the only reason to skip: it HAS issues, just none of this repo's. A
    # board with no issue at all is a board this repo simply has not been put on yet - every open
    # issue is off it, and saying "no comparo" there would hide exactly that.
    $anyIssue = @($Items | Where-Object { $_ -and $_.content -and $_.content.number -and $_.content.type -ne 'DraftIssue' })
    if ($mine.Count -eq 0 -and $anyIssue.Count -gt 0) {
        return @(New-StateFinding -Source 'offboard' -Group 'skipped' -Text "Issues fuera del board: no comparo, este board no tiene ningun item de $Repo.")
    }
    $onBoard = @{}
    foreach ($m in $mine) { $onBoard[[int]$m.content.number] = $true }
    $missing = @($OpenIssues | Where-Object { $_ -and -not $onBoard.ContainsKey([int]$_.number) } |
                 ForEach-Object { [int]$_.number } | Sort-Object)
    if ($missing.Count -eq 0) { return @() }
    @(New-StateFinding -Source 'offboard' -Group 'offboard' `
        -Text ("{0} issue(s) abiertos no estan en el board: {1}." -f $missing.Count, (Format-StateNumberList $missing 15)) `
        -Offer 'agregarlos al board')
}

# Worktrees (other than the one you stand in) whose branch already merged. Pure over rows built by
# Read-StateWorktreeVerdicts: { Path; Branch; Merged [bool]; Pr; Error }. A branch a live session
# still works ($LiveBranches) is in flight, not stale, and a row whose PR could not be read is an
# 'unknown', never assumed merged or unmerged.
function Get-MergedWorktreeFindings {
    param([object[]]$Rows = @(), [string[]]$LiveBranches = @())
    $rows  = @($Rows | Where-Object { $_ })
    $live  = @($LiveBranches | Where-Object { $_ })
    $out   = @()
    $merged = @($rows | Where-Object { -not $_.Error -and $_.Merged -and ($live -notcontains $_.Branch) })
    # A merged branch whose folder still holds uncommitted or untracked files (or whose state could
    # not be read - fail closed) is somebody's live work: it is said, but never offered for cleanup.
    $isClean = { param($r) (-not $r.Dirty) -or $r.Dirty -eq 'clean' }
    $cleanable = @($merged | Where-Object { & $isClean $_ })
    $kept      = @($merged | Where-Object { -not (& $isClean $_) })
    if ($cleanable.Count -gt 0) {
        $desc = @($cleanable | ForEach-Object { "$($_.Branch) (PR #$($_.Pr))" }) -join ', '
        $out += New-StateFinding -Source 'worktree' -Group 'stale' `
            -Text ("{0} worktree(s) de ramas que ya se mergearon: {1}." -f $cleanable.Count, $desc) `
            -Offer 'limpiarlos (con la confirmacion de siempre por rama)'
    }
    if ($kept.Count -gt 0) {
        $desc = @($kept | ForEach-Object { "$($_.Branch) (PR #$($_.Pr))" }) -join ', '
        $out += New-StateFinding -Source 'worktree' -Group 'stale' `
            -Text ("{0} worktree(s) de ramas ya mergeadas, pero con cambios sin commitear (o que no pude comprobar): {1}. Los conservo, no los ofrezco para limpiar." -f $kept.Count, $desc)
    }
    $bad = @($rows | Where-Object { $_.Error })
    if ($bad.Count -gt 0) {
        $out += New-StateFinding -Source 'worktree' -Group 'unknown' `
            -Text ("No pude comprobar el PR de {0} worktree(s): {1}." -f $bad.Count, ((@($bad | ForEach-Object { $_.Branch })) -join ', '))
    }
    return @($out)
}

# What [Unreleased] holds, read from the CHANGELOG text of the DEFAULT branch. Pure. Returns
# { HasSection; Entries }: Entries counts top-level bullets, or 1 when the block has prose but no
# bullet, so a non-empty block can never read as "nothing to release".
function Get-UnreleasedEntryCount {
    param([string]$Text)
    if (-not $Text) { return [pscustomobject]@{ HasSection = $false; Entries = 0 } }
    $m = [regex]::Match($Text, '(?ms)^##[ \t]*\[Unreleased\][ \t]*\r?\n(.*?)(?=^##[ \t]*\[|\z)')
    if (-not $m.Success) { return [pscustomobject]@{ HasSection = $false; Entries = 0 } }
    $bullets = 0; $prose = 0
    foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
        if (-not $line.Trim())            { continue }
        if ($line -match '^#')            { continue }
        if ($line -match '^[-*+]\s+\S')   { $bullets++; continue }
        if ($line -match '^\S')           { $prose++ }
    }
    $entries = if ($bullets -gt 0) { $bullets } elseif ($prose -gt 0) { 1 } else { 0 }
    [pscustomobject]@{ HasSection = $true; Entries = $entries }
}

# A release is due when [Unreleased] carries entries. The commit count and the tag are context for
# the user (how long has this been waiting), not the criterion: commits with nothing under
# [Unreleased] are not a release. Pure over what Read-StateReleaseDelta measured.
function Get-UnreleasedFinding {
    param($Delta)
    if (-not $Delta) { return $null }
    if (-not $Delta.Ok) {
        if ($Delta.Skipped) { return New-StateFinding -Source 'release' -Group 'skipped' -Text "Release: no comparo ($($Delta.Skipped))." }
        return New-StateFinding -Source 'release' -Group 'unknown' -Text "No pude leer el CHANGELOG de la rama por defecto ($($Delta.Error)), asi que no se si hay un release pendiente."
    }
    $u = Get-UnreleasedEntryCount $Delta.Text
    if (-not $u.HasSection -or $u.Entries -eq 0) { return $null }
    $since = if ($Delta.Tag) {
        if ($Delta.Commits -ge 0) { " y hay $($Delta.Commits) commit(s) en $($Delta.BaseRef) desde $($Delta.Tag)" } else { " (ultimo release: $($Delta.Tag))" }
    } else { ' y el repo no tiene ningun tag de release todavia' }
    New-StateFinding -Source 'release' -Group 'due' `
        -Text ("El [Unreleased] del CHANGELOG tiene {0} entrada(s){1}: hay un release pendiente." -f $u.Entries, $since) `
        -Offer 'preparar el release'
}

# ---------------------------------------------------------------------------- presentation

$script:StateGroupOrder = @(
    [pscustomobject]@{ Group = 'inflight'; Label = 'En curso';                                Color = 'Cyan'       }
    [pscustomobject]@{ Group = 'stale';    Label = 'Colgado o listo para cerrar';             Color = 'Yellow'     }
    [pscustomobject]@{ Group = 'offboard'; Label = 'Fuera del board';                         Color = 'Yellow'     }
    [pscustomobject]@{ Group = 'due';      Label = 'Toca hacer';                              Color = 'Yellow'     }
    [pscustomobject]@{ Group = 'unknown';  Label = 'No pude comprobar (no afirmo que este limpio)'; Color = 'Red'   }
)

# A repo is CLEAN when nothing is in flight, stale, off-board, due or unreadable. 'skipped' sources
# do not count against it - they are said, but they are not open work.
function Test-StateOfPlayClean {
    param([object[]]$Findings = @())
    return (@($Findings | Where-Object { $_ -and $_.Group -ne 'skipped' }).Count -eq 0)
}

# The lines to print, as { Text; Color } so a test can read them without a console. Clean -> ONE line
# and nothing else (no ceremony when there is nothing to report). Otherwise the groups in fixed
# order, each finding with its offer, and a closing line that says the tool acts only on a yes.
function Format-StateOfPlay {
    param([object[]]$Findings = @(), [string]$Repo = '')
    $lines = @()
    $all = @($Findings | Where-Object { $_ })
    if (Test-StateOfPlayClean $all) {
        $lines += [pscustomobject]@{ Text = 'Estado del trabajo: sin novedades (nada en curso, colgado, fuera del board ni por releasear).'; Color = 'Green' }
        foreach ($s in @($all | Where-Object { $_.Group -eq 'skipped' })) {
            $lines += [pscustomobject]@{ Text = "  ($($s.Text))"; Color = 'DarkGray' }
        }
        return @($lines)
    }
    $head = if ($Repo) { "=== Estado del trabajo ($Repo) ===" } else { '=== Estado del trabajo ===' }
    $lines += [pscustomobject]@{ Text = $head; Color = 'Cyan' }
    $offers = 0
    foreach ($g in $script:StateGroupOrder) {
        $inGroup = @($all | Where-Object { $_.Group -eq $g.Group })
        if ($inGroup.Count -eq 0) { continue }
        $lines += [pscustomobject]@{ Text = "  $($g.Label):"; Color = $g.Color }
        foreach ($f in $inGroup) {
            $lines += [pscustomobject]@{ Text = "    - $($f.Text)"; Color = $g.Color }
            if ($f.Offer) {
                $offers++
                $lines += [pscustomobject]@{ Text = "        Si quieres, lo hago yo: $($f.Offer)."; Color = 'DarkGray' }
            }
        }
    }
    foreach ($s in @($all | Where-Object { $_.Group -eq 'skipped' })) {
        $lines += [pscustomobject]@{ Text = "  ($($s.Text))"; Color = 'DarkGray' }
    }
    if ($offers -gt 0) {
        $lines += [pscustomobject]@{ Text = '  Dime cuales y los hago; no toco nada sin tu si.'; Color = 'DarkGray' }
    }
    return @($lines)
}

# ------------------------------------------------------------------------------- readers
# The only functions here that touch gh, git or the disk. Each returns a small result object with
# Ok / Error so a failed read is DATA for the classifiers above, never an exception the listing
# dies of and never an empty list that reads as "nothing".

# Every OPEN issue of the repo (number, title, sub-issue summary), paged with the cursor as a
# GraphQL variable (never spliced into the query text). Pull requests are not in `issues`. A read
# that hits the page ceiling is reported as not Ok: a partial list must not be compared against
# the board as if it were whole.
function Read-StateOpenIssues {
    param([Parameter(Mandatory)][string]$Repo, [int]$MaxPages = 40)
    $parts = $Repo -split '/'
    if ($parts.Count -ne 2) { return [pscustomobject]@{ Ok = $false; Issues = @(); Error = "repo '$Repo' no tiene la forma owner/name" } }
    $query = 'query($o:String!,$r:String!,$cursor:String){repository(owner:$o,name:$r){issues(states:OPEN,first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{number title subIssuesSummary{total completed}}}}}'
    $all = @(); $cursor = ''; $pages = 0
    try {
        do {
            $ghArgs = @('api', 'graphql', '-f', "query=$query", '-f', "o=$($parts[0])", '-f', "r=$($parts[1])")
            if ($cursor) { $ghArgs += @('-f', "cursor=$cursor") }
            $resp = Invoke-Gh -GhArgs $ghArgs -What "leer los issues abiertos de $Repo" -Graphql
            $page = $resp.data.repository.issues
            if (-not $page -or -not $page.pageInfo) { throw "respuesta sin la lista de issues de $Repo" }
            $all += @($page.nodes | Where-Object { $null -ne $_ })
            $cursor = if ($page.pageInfo.hasNextPage) { [string]$page.pageInfo.endCursor } else { '' }
            $pages++
        } while ($cursor -and $pages -lt $MaxPages)
    } catch {
        return [pscustomobject]@{ Ok = $false; Issues = @(); Error = $_.Exception.Message }
    }
    if ($cursor) { return [pscustomobject]@{ Ok = $false; Issues = @(); Error = "mas de $($MaxPages * 100) issues abiertos; no leo la lista entera" } }
    [pscustomobject]@{ Ok = $true; Issues = @($all); Error = '' }
}

function Read-StateOpenPrs {
    param([Parameter(Mandatory)][string]$Repo, [int]$Cap = 100)
    try {
        $prs = @((Invoke-Gh -GhArgs @('pr', 'list', '--repo', $Repo, '--state', 'open', '--limit', "$Cap",
                                      '--json', 'number,title,headRefName,isDraft') `
                            -What "listar los PRs abiertos de $Repo" -Json) | Where-Object { $null -ne $_ })
        [pscustomobject]@{ Ok = $true; Prs = $prs; Error = '' }
    } catch {
        [pscustomobject]@{ Ok = $false; Prs = @(); Error = $_.Exception.Message }
    }
}

# The run marker as the executing file says it is. Missing = no run (Ok, Marker $null); present
# but unparseable is NOT "no run" - it is an unknown.
function Read-StateRunMarker {
    param([string]$StateDir)
    if (-not $StateDir) { return [pscustomobject]@{ Ok = $true; Marker = $null; Error = '' } }
    $p = Join-Path $StateDir 'active-run.json'
    if (-not (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Ok = $true; Marker = $null; Error = '' } }
    try {
        $m = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        [pscustomobject]@{ Ok = $true; Marker = $m; Error = '' }
    } catch {
        [pscustomobject]@{ Ok = $false; Marker = $null; Error = "active-run.json ilegible: $($_.Exception.Message)" }
    }
}

# One row per LINKED worktree (never the main working copy, never the one this session stands in,
# never a detached/locked/prunable one): does its branch's PR say MERGED with this very tip? The
# verdict is Get-SessionCompletion - the same predicate the teardown and the doctor use - so the
# three can never disagree about what "merged" means. Ancestry is never consulted: this repo
# squash-merges.
function Read-StateWorktreeVerdicts {
    param([Parameter(Mandatory)][string]$Repo)
    $porcelain = @(git worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Rows = @(); Error = 'git worktree list fallo' } }
    $records = @(Get-WorktreeRecords -Porcelain ($porcelain -join "`n"))
    $top = "$(@(git rev-parse --show-toplevel 2>$null)[0])".Trim()
    $curBranch = "$(@(git branch --show-current 2>$null)[0])".Trim()
    $norm = { param($p) (("$p") -replace '\\', '/').TrimEnd('/') }
    $rows = @()
    $i = 0
    foreach ($w in $records) {
        $i++
        if ($i -eq 1)                    { continue }   # git lists the main working copy first
        if ($w.Bare -or $w.Detached -or $w.Locked -or $w.Prunable -or -not $w.Branch) { continue }
        if ($top -and ((& $norm $w.Path) -ieq (& $norm $top))) { continue }
        if ($curBranch -and $w.Branch -eq $curBranch)          { continue }
        try {
            $prs = @((Invoke-Gh -GhArgs @('pr', 'list', '--repo', $Repo, '--head', $w.Branch, '--state', 'all',
                                          '--json', 'number,state,headRefOid', '--limit', '20') `
                                -What "leer el PR de la rama $($w.Branch)" -Json) | Where-Object { $null -ne $_ })
            $mine = @($prs | Where-Object { $w.Head -and $_.headRefOid -eq $w.Head }) | Select-Object -First 1
            $merged = $false; $pr = 0
            if ($mine) {
                $v = Get-SessionCompletion -PrState ([string]$mine.state) -PrHeadOid ([string]$mine.headRefOid) -BranchTip ([string]$w.Head)
                $merged = [bool]$v.merged; $pr = [int]$mine.number
            }
            # Only a merged branch needs the folder checked; --untracked-files=all so a new file counts.
            # Fail closed: a git error is 'unknown', never 'clean'.
            $dirty = 'clean'
            if ($merged) {
                $st = @(git -C $w.Path status --porcelain --untracked-files=all 2>$null)
                if ($LASTEXITCODE -ne 0) { $dirty = 'unknown' }
                elseif ((@($st) -join '').Trim()) { $dirty = 'dirty' }
            }
            $rows += [pscustomobject]@{ Path = $w.Path; Branch = $w.Branch; Merged = $merged; Pr = $pr; Dirty = $dirty; Error = '' }
        } catch {
            $rows += [pscustomobject]@{ Path = $w.Path; Branch = $w.Branch; Merged = $false; Pr = 0; Error = $_.Exception.Message }
        }
    }
    [pscustomobject]@{ Ok = $true; Rows = @($rows); Error = '' }
}

# The DEFAULT branch's CHANGELOG (read from the ref, not the working tree: a feature branch with a
# half-edited CHANGELOG is not what is unreleased) and its distance from the last release tag.
function Read-StateReleaseDelta {
    param([string]$BaseRef)
    if (-not $BaseRef) { return [pscustomobject]@{ Ok = $false; Skipped = 'no pude resolver la rama por defecto'; Error = '' } }
    $blob = @(git show "${BaseRef}:CHANGELOG.md" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Ok = $false; Skipped = "$BaseRef no tiene un CHANGELOG.md en la raiz"; Error = '' }
    }
    $tag = "$(@(git describe --tags --abbrev=0 $BaseRef 2>$null)[0])".Trim()
    if ($LASTEXITCODE -ne 0) { $tag = '' }
    $commits = -1
    if ($tag) {
        $c = "$(@(git rev-list --count "$tag..$BaseRef" 2>$null)[0])".Trim()
        if ($LASTEXITCODE -eq 0 -and $c -match '^\d+$') { $commits = [int]$c }
    }
    [pscustomobject]@{ Ok = $true; Text = ($blob -join "`n"); Tag = $tag; Commits = $commits; BaseRef = $BaseRef; Skipped = ''; Error = '' }
}

# ------------------------------------------------------------------------------ orchestrator

# Gather the findings for one repo. $Repo = the repo whose work we describe ('' = only the board
# could be described); $HereRepo = the repo of the clone we stand in. The marker, the worktrees and
# the CHANGELOG belong to a CLONE, so they are only read when the two are the same repo - reading
# another repo's issues against THIS clone's worktrees would be describing two different projects.
function Get-StateOfPlay {
    param(
        [string]$Repo = '', [string]$HereRepo = '',
        [object[]]$Items = @(), [bool]$BoardTruncated = $false,
        [string]$StateDir = '', [string[]]$LiveBranches = @(), [bool]$LiveKnown = $true, [string]$BaseRef = ''
    )
    $f = @()
    $f += @(Get-BoardInFlightFindings -Items $Items)

    if (-not $Repo) {
        $f += New-StateFinding -Source 'scope' -Group 'skipped' -Text 'No estoy dentro de un repo git: solo puedo describir el board, no las corridas, worktrees ni releases.'
        return @($f)
    }

    $open = Read-StateOpenIssues -Repo $Repo
    $openNums = @($open.Issues | ForEach-Object { [int]$_.number })
    if ($open.Ok) { $f += @(Get-FinishedEpicFindings -OpenIssues $open.Issues) }
    else          { $f += New-StateFinding -Source 'epic' -Group 'unknown' -Text "No pude leer los issues abiertos de $Repo ($($open.Error)), asi que no se si algun epic esta listo para cerrar." }
    $f += @(Get-OffBoardFindings -OpenIssues $open.Issues -Items $Items -Repo $Repo -OpenVerified $open.Ok -BoardTruncated $BoardTruncated)

    $prs = Read-StateOpenPrs -Repo $Repo
    if ($prs.Ok) { $f += @(Get-OpenPrFindings -Prs $prs.Prs) }
    else         { $f += New-StateFinding -Source 'pr' -Group 'unknown' -Text "No pude listar los PRs abiertos de $Repo ($($prs.Error))." }

    $local = [bool]($HereRepo -and ($HereRepo -ieq $Repo))
    if (-not $local) {
        $f += New-StateFinding -Source 'local' -Group 'skipped' -Text "Corridas, worktrees y release: no los miro, esta carpeta no es un clon de $Repo."
        return @($f)
    }

    $marker = Read-StateRunMarker -StateDir $StateDir
    if (-not $marker.Ok) { $f += New-StateFinding -Source 'run' -Group 'unknown' -Text "No pude leer el registro de la corrida autonoma ($($marker.Error))." }
    else {
        $rf = Get-RunMarkerFinding -Marker $marker.Marker -OpenNumbers $openNums -Verified $open.Ok
        if ($rf) { $f += $rf }
    }

    $wt = Read-StateWorktreeVerdicts -Repo $Repo
    if (-not $LiveKnown) {
        # Without the live-session list a merged worktree could belong to a session still working it.
        $f += New-StateFinding -Source 'worktree' -Group 'unknown' -Text 'No pude leer el registro de sesiones vivas, asi que no ofrezco limpiar worktrees (uno podria tener una sesion trabajandolo).'
    }
    elseif ($wt.Ok) { $f += @(Get-MergedWorktreeFindings -Rows $wt.Rows -LiveBranches $LiveBranches) }
    else        { $f += New-StateFinding -Source 'worktree' -Group 'unknown' -Text "No pude listar los worktrees ($($wt.Error))." }

    $rel = Get-UnreleasedFinding -Delta (Read-StateReleaseDelta -BaseRef $BaseRef)
    if ($rel) { $f += $rel }
    return @($f)
}
