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
            "address feedback and re-run until every one is green (all of them at once: pwsh $($Refs['Board-ReviewGate']) -Issue $IssueNum - the run passes only when every PR passes) ; ")
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

# ------------------------------------------------------------------ gate and closure (#487, 3 and 5)

# The PRs recorded for an issue's session(s) in sessions.json rows, as "owner/name#n" strings, in
# order of recording, de-duplicated. PURE over the rows. An issue with no row, or a row with no
# recorded PR, yields an empty list - and every caller treats empty as "nothing to gate / nothing
# to close", never as "all clear".
function Get-RecordedPullRequests {
    param([object[]]$Entries = @(), [int]$Issue)
    $out = @(); $seen = @{}
    foreach ($e in @($Entries | Where-Object { $_ -and [int]$_.issue -eq $Issue })) {
        if (-not $e.PSObject.Properties['prs']) { continue }
        foreach ($p in @($e.prs | Where-Object { $_ -and $_.repo -and $_.number })) {
            $k = "$($p.repo)#$($p.number)"
            if ($seen.ContainsKey($k.ToLowerInvariant())) { continue }
            $seen[$k.ToLowerInvariant()] = $true; $out += $k
        }
    }
    return @($out)
}

# May the issue be closed? PURE. It may ONLY when: at least one PR is recorded, EVERY recorded PR is
# MERGED (from a live read), and every target repo the issue declares has a recorded PR. Anything
# else - a PR still open or closed unmerged, a PR whose state could not be read, a declared target
# with no PR - is a refusal that names the reason. Never closes on the first merged PR.
#   $Prs     recorded rows { repo; number }      $States  "repo#n" -> OPEN|MERGED|CLOSED (absent = unknown)
#   $TargetRepos the issue's declared target repos (may be empty)
# Returns { CanClose; Reason; Merged; Total; Unknown; NotMerged; Unrecorded }
function Get-IssueClosureVerdict {
    param([object[]]$Prs = @(), [hashtable]$States = @{}, [string[]]$TargetRepos = @())
    $rows = @($Prs | Where-Object { $_ -and $_.repo -and $_.number })
    $unknown = @(); $notMerged = @(); $merged = 0
    foreach ($p in $rows) {
        $k = "$($p.repo)#$($p.number)"
        if (-not $States.ContainsKey($k) -or -not $States[$k]) { $unknown += $k; continue }
        if ($States[$k] -eq 'MERGED') { $merged++ } else { $notMerged += $k }
    }
    $have = @{}; foreach ($p in $rows) { $have["$($p.repo)".ToLowerInvariant()] = $true }
    $unrecorded = @(@($TargetRepos | Where-Object { $_ }) | Where-Object { -not $have.ContainsKey($_.ToLowerInvariant()) })
    $reason = ''
    if ($rows.Count -eq 0)           { $reason = 'no hay ningun PR anotado para este issue' }
    elseif ($unknown.Count -gt 0)    { $reason = "no pude leer el estado de: $($unknown -join ', ')" }
    elseif ($notMerged.Count -gt 0)  { $reason = "siguen sin mergear: $($notMerged -join ', ')" }
    elseif ($unrecorded.Count -gt 0) { $reason = "repos objetivo sin PR anotado: $($unrecorded -join ', ')" }
    [pscustomobject]@{
        CanClose = ($reason -eq ''); Reason = $reason; Merged = $merged; Total = $rows.Count
        Unknown = @($unknown); NotMerged = @($notMerged); Unrecorded = @($unrecorded)
    }
}

# The closure plan of one issue's session, read from the executing sources: the registry row for the
# recorded PRs + targets and a LIVE state per PR. { Ok; Error; Repo; Prs; States; Verdict }.
function Get-CrossRepoClosurePlan {
    param([Parameter(Mandatory)][int]$IssueNum)
    $p = Get-SessionRegistryPath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        return [pscustomobject]@{ Ok = $false; Error = "no hay registro de sesiones (sessions.json): el issue #$IssueNum no tiene sesion registrada." }
    }
    try { $entries = @(Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ Ok = $false; Error = "sessions.json ilegible ($($_.Exception.Message)): no cierro nada." } }
    $mine = @($entries | Where-Object { [int]$_.issue -eq $IssueNum })
    if ($mine.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Error = "el issue #$IssueNum no tiene sesion registrada." } }
    $repo = "$(@($mine | Where-Object { $_.repo } | Select-Object -First 1).repo)"
    if (-not $repo) { return [pscustomobject]@{ Ok = $false; Error = "la sesion del issue #$IssueNum no registra su repo: no se donde cerrarlo." } }
    $refs = @(Get-RecordedPullRequests -Entries $mine -Issue $IssueNum)
    $prs = @($refs | ForEach-Object { $r = Get-PullRequestRef $_; if ($r) { [pscustomobject]@{ repo = $r.Repo; number = $r.Number } } })
    $targets = @()
    foreach ($e in $mine) { if ($e.PSObject.Properties['targetRepos']) { $targets += @($e.targetRepos | Where-Object { $_ }) } }
    $states = Get-SessionPrStates -Prs $prs
    [pscustomobject]@{
        Ok = $true; Error = ''; Repo = $repo; Prs = $prs; States = $states
        Verdict = (Get-IssueClosureVerdict -Prs $prs -States $states -TargetRepos @($targets | Select-Object -Unique))
    }
}

# The lines that show the plan, so the user sees exactly what would be closed and why. PURE.
function Format-ClosurePlanLines {
    param([int]$IssueNum, [string]$Repo, [object[]]$Prs = @(), [hashtable]$States = @{}, $Verdict)
    $lines = @("Issue $Repo#$IssueNum - PRs anotados:")
    foreach ($p in @($Prs)) {
        $k = "$($p.repo)#$($p.number)"
        $st = if ($States.ContainsKey($k)) { $States[$k] } else { 'estado desconocido' }
        $lines += "  - $k [$st]"
    }
    if (@($Prs).Count -eq 0) { $lines += '  (ninguno)' }
    $lines += if ($Verdict.CanClose) { "Todos mergeados ($($Verdict.Merged) de $($Verdict.Total)): el issue se puede cerrar." }
              else                   { "NO se cierra: $($Verdict.Reason)." }
    return @($lines)
}

# ---------------------------------------------------------------- multi-PR review gate

# "owner/name#n" or "n" (with a default repo) -> { Repo; Number }, or $null when it is neither.
# PURE. A bare number without a default repo is refused (null): the gate must never guess which repo.
function Resolve-GatePullRequest {
    param([string]$Spec, [string]$DefaultRepo = '')
    $ref = Get-PullRequestRef $Spec
    if ($ref) { return $ref }
    if ($Spec -and $Spec.Trim() -match '^\d+$' -and [int]$Spec.Trim() -gt 0 -and $DefaultRepo) {
        return [pscustomobject]@{ Repo = $DefaultRepo; Number = [int]$Spec.Trim() }
    }
    return $null
}

# What one PR's single-PR gate exit code MEANS, for the run verdict. PURE. The single gate's own
# codes are unchanged (0 pass, 1 block, 2 unreviewed, 3 CI not evaluated); a missing or unexpected
# code - the child could not run, was killed, printed nothing - is 'unknown', never a pass.
function Get-GateVerdictName {
    param($ExitCode)
    if ($null -eq $ExitCode -or "$ExitCode" -notmatch '^-?\d+$') { return 'unknown' }
    switch ([int]$ExitCode) {
        0 { return 'pass' }
        1 { return 'block' }
        2 { return 'unreviewed' }
        3 { return 'ci-not-evaluated' }
        default { return 'unknown' }
    }
}

# The run verdict over the per-PR verdicts, and the exit code for it. PURE. It can only ESCALATE:
# a PR the single gate blocked is a block here, and the run passes only when there is at least one
# PR and EVERY PR passed. Ranking (worst first): block 1, unknown 4, ci-not-evaluated 3,
# unreviewed 2, pass 0. Exit 4 exists only in multi-PR mode; the single -PR path never returns it.
function Get-GateRunVerdict {
    param([string[]]$Verdicts = @())
    $v = @($Verdicts | Where-Object { $_ })
    if ($v.Count -eq 0)                  { return [pscustomobject]@{ Name = 'unknown';          ExitCode = 4 } }
    if ($v -contains 'block')            { return [pscustomobject]@{ Name = 'block';            ExitCode = 1 } }
    if ($v -contains 'unknown')          { return [pscustomobject]@{ Name = 'unknown';          ExitCode = 4 } }
    if ($v -contains 'ci-not-evaluated') { return [pscustomobject]@{ Name = 'ci-not-evaluated'; ExitCode = 3 } }
    if ($v -contains 'unreviewed')       { return [pscustomobject]@{ Name = 'unreviewed';       ExitCode = 2 } }
    if (@($v | Where-Object { $_ -ne 'pass' }).Count -eq 0) { return [pscustomobject]@{ Name = 'pass'; ExitCode = 0 } }
    return [pscustomobject]@{ Name = 'unknown'; ExitCode = 4 }
}

# The argument list for ONE PR's single-PR gate, forwarding the caller's own gate switches so each
# PR is judged by exactly the rules the caller asked for. PURE over the bound parameters.
# -RecordReview, -InstallRuleset and the multi-PR selectors are never forwarded (they are refused
# earlier); switches are forwarded only when the caller passed them.
function Get-GateChildArgs {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][int]$Number, [System.Collections.IDictionary]$Bound = @{})
    $a = @('-Repo', $Repo, '-PR', "$Number")
    foreach ($n in 'TimeoutMinutes', 'CiTimeoutMinutes', 'MaxLines', 'MaxFiles', 'CopilotCooldownDays', 'TokenVar') {
        if (@($Bound.Keys) -contains $n) { $a += @("-$n", "$($Bound[$n])") }
    }
    foreach ($n in 'EnableCopilot', 'AllowUnreviewed', 'RequireIndependentReviewer', 'PreferCodexRescue') {
        if ((@($Bound.Keys) -contains $n) -and [bool]$Bound[$n]) { $a += "-$n" }
    }
    return @($a)
}
