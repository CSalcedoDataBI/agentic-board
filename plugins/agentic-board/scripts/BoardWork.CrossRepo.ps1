# BoardWork.CrossRepo.ps1 - issues whose work lives in OTHER repositories (#487).
#
# The fleet used to assume 1 issue = 1 repo = 1 worktree = 1 PR. An issue whose work goes to other
# repos (positioning, licences, CI templates, README, topics - this tool exists to install things
# into other repos) fit no part of that flow: the briefing told the session to implement it in the
# worktree, the registry said "1 session, 1 worktree" while several PRs were live in several repos,
# and a `Closes #n` in a PR of another repo would have pointed at THAT repo's issue #n.
#
# What this file provides is the safe minimum the issue names (its points 1, 2 and 4):
#   1. detect the case      - Get-IssueTargetRepos (a `cross-repo` label, or a target-repos list in the body)
#   2. a briefing that knows - Format-CrossRepoBriefing (worktree = base, one PR per target repo, `Refs` not `Closes`)
#   4. a registry that tells the truth - Add-SessionPullRequest / Get-PullRequestRef (PRs recorded per session)
#
# Not here, on purpose (product decisions, see the PR): a plural review gate, and closing the issue
# when ALL its PRs merge. Nothing in this file closes an issue.
#
# Function definitions only. Pure at load (no gh, no git, no output).

# The headings/labels an issue may use to declare its targets. A body list is the declaration; the
# label alone says "this is cross-repo" without naming where.
$script:CrossRepoLabel = 'cross-repo'
$script:TargetReposHeader = '(?i)^\s*(?:#{1,6}\s*)?\**\s*(?:target\s+repos(?:itories)?|repos?\s+objetivo|repositorios?\s+objetivo)\s*\**\s*:?\s*\**\s*(?<rest>.*)$'

# One `owner/name` from a token, accepting a bare slug, a backticked one or a github.com URL.
# Returns $null when the token is not a repository reference.
function ConvertTo-RepoSlug {
    param([string]$Token)
    if (-not $Token) { return $null }
    $t = $Token.Trim().Trim('`', '"', "'", '*', '(', ')', ',', ';', '.')
    $t = $t -replace '^(?i)https?://github\.com/', ''
    $t = $t -replace '(?i)\.git$', ''
    $t = $t.TrimEnd('/')
    if ($t -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return $t }
    return $null
}

# Which repositories does this issue say its work goes to? PURE. Returns
#   { CrossRepo [bool]; Repos [string[]] }
# Repos = the declared targets OTHER than the issue's own repo (case-insensitive, de-duplicated, in
# order of appearance). CrossRepo = the `cross-repo` label is present, or at least one such target
# is declared. A list naming only the issue's own repo is NOT cross-repo. A label with no list is
# cross-repo with Repos empty: the session is told to find the targets in the issue itself.
#
# The body syntax is deliberately small and explicit - a header line (`Target repos:`, `## Target
# repos`, `Repos objetivo:`) followed by a list, or the slugs inline after the colon - because a
# guess at prose would invent targets, and a wrong target repo is a PR opened in the wrong project.
function Get-IssueTargetRepos {
    param([string]$Body = '', [string[]]$Labels = @(), [string]$HomeRepo = '')
    $found = New-Object System.Collections.Generic.List[string]
    $lines = @(($Body -split "`r?`n"))
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], $script:TargetReposHeader)
        if (-not $m.Success) { continue }
        # Inline form: `Target repos: a/b, c/d`.
        # ALL-or-nothing: a sentence that merely happens to contain a slashed word ("Target repos:
        # update the a/b module and TCP/IP") is prose, not a declaration, and must not invent targets.
        $restTokens = @($m.Groups['rest'].Value -split '[,\s]+' | Where-Object { $_ })
        $restSlugs  = @($restTokens | ForEach-Object { ConvertTo-RepoSlug $_ })
        if ($restTokens.Count -gt 0 -and -not ($restSlugs -contains $null) -and @($restSlugs | Where-Object { -not $_ }).Count -eq 0) {
            foreach ($slug in $restSlugs) { $found.Add($slug) }
        }
        # List form: the items right under the header; a blank line after at least one item, or any
        # non-list line, ends the block.
        $seenItem = $false
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $ln = $lines[$j]
            if (-not $ln.Trim()) { if ($seenItem) { break } else { continue } }
            $item = [regex]::Match($ln, '^\s*(?:[-*+]|\d+[.)])\s+(?<tok>\S+)')
            if (-not $item.Success) { break }
            $slug = ConvertTo-RepoSlug $item.Groups['tok'].Value
            if (-not $slug) { break }
            $found.Add($slug); $seenItem = $true
        }
        $i = $j - 1
    }
    $repos = @(); $seen = @{}
    foreach ($s in $found) {
        $k = $s.ToLowerInvariant()
        if ($HomeRepo -and $k -eq $HomeRepo.ToLowerInvariant()) { continue }
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true; $repos += $s
    }
    $label = [bool](@($Labels | Where-Object { $_ -and ($_ -ieq $script:CrossRepoLabel) }).Count)
    [pscustomobject]@{ CrossRepo = ($label -or $repos.Count -gt 0); Repos = @($repos) }
}

# `owner/name#123` (or a github.com PR URL) -> { Repo; Number }, or $null. PURE.
function Get-PullRequestRef {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    if ($t -match '(?i)^https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)/?$') {
        return [pscustomobject]@{ Repo = $Matches[1]; Number = [int]$Matches[2] }
    }
    if ($t -match '^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)$') {
        return [pscustomobject]@{ Repo = $Matches[1]; Number = [int]$Matches[2] }
    }
    return $null
}

# Add one PR to a session's recorded list without duplicating it. PURE: returns the NEW list.
function Merge-SessionPullRequest {
    param([object[]]$Existing = @(), [string]$Repo, [int]$Number)
    $list = @($Existing | Where-Object { $_ -and $_.repo -and $_.number })
    $has = @($list | Where-Object { ("$($_.repo)" -ieq $Repo) -and ([int]$_.number -eq $Number) }).Count -gt 0
    if (-not $has) { $list += [pscustomobject]@{ repo = $Repo; number = $Number } }
    return @($list)
}

# The cross-repo part of the session briefing, replacing steps (2)-(4) of the single-repo flow.
# PURE. $Refs maps script name -> how to run it (Resolve-BriefingScriptRef). The two rules that make
# it safe: the PR body must say `Refs`, never `Closes` (a `Closes #n` in another repo closes THAT
# repo's issue #n), and the session must not close the issue itself (it closes when ALL the PRs have
# merged, which is the human's call).
function Format-CrossRepoBriefing {
    param([int]$IssueNum, [string]$HomeRepo, [string[]]$TargetRepos = @(), [hashtable]$Refs)
    $where = if (@($TargetRepos).Count -gt 0) {
        "its work lands in these OTHER repositories: " + (@($TargetRepos) -join ', ')
    } else {
        "its work lands in OTHER repositories that the issue itself names - read it to find every one"
    }
    return ("(2) THIS ISSUE IS CROSS-REPO: $where. This worktree is your base of operations, NOT the destination of the changes. " +
            "For EACH target repo, work in a clone or worktree of THAT repo (make one if it is missing), on its own branch, and commit there ; " +
            "(3) open ONE PR per target repo, from inside that repo's working copy, with: " +
            "pwsh $($Refs['New-BoardPR']) -Issue $IssueNum -IssueRepo $HomeRepo -Repo <target owner/name> " +
            "- it writes 'Refs $HomeRepo#$IssueNum' instead of 'Closes', because a 'Closes #$IssueNum' in another repo would close THAT repo's own issue #$IssueNum. " +
            "IMMEDIATELY after EACH PR is opened, record it so the fleet dashboard shows what is really live: " +
            "pwsh $($Refs['Board-Work']) -RecordPr <target owner/name>#<pr number> -ForIssue $IssueNum ; " +
            "(4) pass the review gate on EACH PR: pwsh $($Refs['Board-ReviewGate']) -Repo <target owner/name> -PR <pr> ; " +
            "address feedback and re-run until every one is green ; ")
}

# ------------------------------------------------------------------------------- registry IO

# Record a PR opened by a session, in .agentic-board/sessions.json. Returns { Ok; Message }. A PR
# with no registered session to hang on is REFUSED (Ok = $false), never turned into a phantom row:
# a dashboard that invents a session is as wrong as one that omits a PR.
function Add-SessionPullRequest {
    param([Parameter(Mandatory)][int]$IssueNum, [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Number)
    $p = Get-SessionRegistryPath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ Ok = $false; Message = "no hay registro de sesiones (sessions.json): el issue #$IssueNum no tiene sesion registrada donde anotar el PR." }
    }
    try { $entries = @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ Ok = $false; Message = "sessions.json ilegible ($($_.Exception.Message)): no lo toco." } }
    $mine = @($entries | Where-Object { [int]$_.issue -eq $IssueNum })
    if ($mine.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Message = "el issue #$IssueNum no tiene sesion registrada: no invento una para anotar el PR." }
    }
    $out = @()
    foreach ($e in $entries) {
        if ([int]$e.issue -eq $IssueNum) {
            $prs = Merge-SessionPullRequest -Existing @($e.prs) -Repo $Repo -Number $Number
            if ($e.PSObject.Properties['prs']) { $e.prs = @($prs) } else { $e | Add-Member -NotePropertyName prs -NotePropertyValue @($prs) }
        }
        $out += $e
    }
    $out | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $p
    [pscustomobject]@{ Ok = $true; Message = "PR $Repo#$Number anotado en la sesion del issue #$IssueNum." }
}

# ------------------------------------------------------------------------- dashboard

# Live state of each recorded PR ("OPEN" | "MERGED" | "CLOSED"), keyed "owner/name#n". A PR whose
# state could not be read is simply absent from the map (the dashboard prints it as unknown).
function Get-SessionPrStates {
    param([object[]]$Prs = @())
    $states = @{}
    foreach ($p in @($Prs | Where-Object { $_ -and $_.repo -and $_.number })) {
        try {
            $one = Invoke-Gh -GhArgs @('pr', 'view', "$($p.number)", '--repo', "$($p.repo)", '--json', 'state') `
                             -What "leer el PR $($p.repo)#$($p.number)" -Json
            if ($one -and $one.state) { $states["$($p.repo)#$($p.number)"] = [string]$one.state }
        } catch { }
    }
    return $states
}

# The dashboard lines for a session's recorded PRs. PURE over the recorded list and the state map.
# Says how many of them are merged, and that the issue is NOT closed by any single one of them:
# with `Refs` PRs nothing closes it automatically, so it closes when ALL are merged, by hand.
function Format-SessionPrLines {
    param([object[]]$Prs = @(), [hashtable]$States = @{})
    $rows = @($Prs | Where-Object { $_ -and $_.repo -and $_.number })
    if ($rows.Count -eq 0) { return @() }
    $lines = @()
    $merged = 0
    foreach ($p in $rows) {
        $k = "$($p.repo)#$($p.number)"
        $st = if ($States.ContainsKey($k)) { $States[$k] } else { 'estado desconocido' }
        if ($st -eq 'MERGED') { $merged++ }
        $lines += "PR $k [$st]"
    }
    $lines += ("{0} de {1} PR(s) mergeados - el issue no se cierra solo con ninguno: se cierra cuando estan todos." -f $merged, $rows.Count)
    return @($lines)
}