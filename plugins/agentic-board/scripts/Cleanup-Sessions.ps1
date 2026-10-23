<#
.SYNOPSIS
    /cleanup sessions: close every session on the machine and leave nothing dangling (#734).

.DESCRIPTION
    `/board close-cycle` closes the CURRENT branch. This is the sweep over all of them, for the
    moment the sidebar is full of old sessions and nobody remembers which one still holds work.

    For every local branch of every scanned repo it takes ONE disposition, reusing the branch
    inventory of `/board doctor` (Board-Doctor.ps1 -Json) instead of re-classifying:

      teardown        PR merged at the tip       -> delete branch + worktree (Board-Doctor -Fix -Auto)
      park            commits, no PR (or commits after a merge)
                                                  -> push + DRAFT PR labelled `parked`, so the
                                                     default branch knows it exists without merging it
      wip-park        uncommitted changes         -> commit them as WIP on their branch, then park
      keep-review     PR open                     -> nothing: the PR already makes it visible
      delete-empty    clean, no commits           -> delete it: there is no work to lose
      delete-contained clean, and `git merge-tree --write-tree` proves its content is already on the
                      default branch (squash-merged through another PR) -> delete it (#755)
      needs-decision  PR closed unmerged / unreadable state / "likely superseded by #N"
                                                  -> left alone, reported with the reason
      skip-open       a session is still working it -> left alone

    Then it decides, for each session of the host app (read from -HostSessionsFile, the JSON the
    agent gets from the app's session list), whether it may be ARCHIVED: only when the work
    behind it is resolved. It never archives anything itself - the app's archive tool does that,
    driven by the agent from the `archive` list this script prints. Archiving is reversible and
    nothing here deletes a transcript (compressing old ones is #736).

    SAFE BY DEFAULT: without -Force it only prints the plan. With -Force it runs the git side,
    and a step that fails turns that branch back into "not resolved", so its session is kept.

.PARAMETER Scope
    repo (default) - only THIS repo: its branches and the sessions that live in it. Run it from
                     each repo you want to clean; nothing outside it is read for archiving or touched.
    orphans        - only the sessions no existing repo owns (folder gone, or outside any repo).
                     No branch of any repo is touched.
    all            - every repo a session lives in, plus -Root folders. The machine-wide sweep.

.PARAMETER Root
    With -Scope all: also sweep every git repo directly under this folder (e.g. C:\src).

.PARAMETER HostSessionsFile
    JSON array of host-app sessions ({ sessionId, title, cwd, isRunning, lastActivityAt, pinned,
    link }), as the app's session list returns them. Without it only the git side is planned.

.PARAMETER IdleDays
    A session not tied to any branch (repo root on the default branch, or outside any repo) is
    archived only after this many days without activity. Default 7.

.PARAMETER Owner
    The accounts whose repos may be PARKED (pushed + draft PR). Default: the login of the token.
    In any other owner's repo only the local cleanup runs; parking there is left as a decision.

.PARAMETER Force
    Execute the git side. Without it nothing is written.

.PARAMETER Json
    Emit the plan (and, with -Force, the outcome) as JSON for the agent.

.EXAMPLE
    .\Cleanup-Sessions.ps1 -HostSessionsFile s.json               # plan for THIS repo
    .\Cleanup-Sessions.ps1 -HostSessionsFile s.json -Force -Json  # run it for this repo
    .\Cleanup-Sessions.ps1 -Scope orphans -HostSessionsFile s.json  # sessions no repo owns
    .\Cleanup-Sessions.ps1 -Scope all -Root C:\src -HostSessionsFile s.json -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('repo', 'orphans', 'all')]
    [string]$Scope            = 'repo',
    [string[]]$Root           = @(),
    [string]$HostSessionsFile = "",
    [int]   $IdleDays         = 7,
    [string[]]$Owner          = @(),
    [switch]$Force,
    [switch]$Json,
    [string]$TokenVar         = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------ pure helpers

# One comparable form for a path: forward and back slashes alike, no trailing separator,
# case-folded (Windows paths are case-insensitive; the host app and git disagree on case).
function ConvertTo-SweepPath {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return '' }
    return ($Path.Trim() -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

# The ONE disposition of a branch. PURE: every fact is an argument.
#   $Class          - the Board-Doctor class: merged | merged-advanced | in-review | closed-unmerged
#                     | active | dirty | stale | working
#   $Dirty          - clean | dirty | unknown  (unknown = fail closed)
#   $HasLiveSession - the session registry says a live session owns it
#   $SessionOpen    - a host-app session or a live Claude process is running in its worktree
#   $CommitsAhead   - commits not on the default branch; -1 = could not tell
#   $ForeignOwner   - the repo belongs to another account than the one running the sweep
# Returns { Action; Resolved; Reason }. Resolved = after the action, nothing is left behind this
# branch that only a local session knows about - the condition for archiving its session.
# Order is meaning: a working session vetoes everything, and uncommitted work is saved before
# any PR state is looked at (the same rule as the single-branch close-cycle).
# Parking PUBLISHES: it pushes and opens a PR. In a repo of another account (a client or business
# repo the personal token happens to read) that would publish under the wrong identity, so there
# it becomes a decision. Local-only actions (teardown, delete-empty) still run.
function Get-SweepItemAction {
    param(
        [string]$Class,
        [string]$Dirty = 'clean',
        [bool]  $HasLiveSession = $false,
        [bool]  $SessionOpen = $false,
        [int]   $CommitsAhead = 0,
        [string]$ForeignOwner = '',
        # commits on the local branch that its remote branch does not have; -1 = could not tell
        [int]   $Unpushed = 0,
        # Get-SweepContainment of the branch against the default branch ('' = not measured)
        [string]$Containment = '',
        # Get-SweepSupersededHint: the PR(s) that most likely already did this work ('' = none)
        [string]$SupersededBy = ''
    )
    $mk = { param($a, $r, $why)
        if ($ForeignOwner -and $a -in @('park', 'wip-park')) {
            $why = "repo of another account ($ForeignOwner): parking would push and open a PR there under this identity - run the sweep as that account, or decide by hand. Found: $why"
            $a = 'needs-decision'; $r = $false
        }
        [pscustomobject]@{ Action = $a; Resolved = $r; Reason = $why } }
    if ($HasLiveSession -or $SessionOpen -or $Class -eq 'active') {
        return (& $mk 'skip-open' $false 'a session is still working on this branch')
    }
    if ($Dirty -eq 'unknown') {
        return (& $mk 'needs-decision' $false 'could not read whether the worktree has uncommitted changes')
    }
    # Work that reached the default branch through ANOTHER PR (squash-merged, cherry-picked - the
    # usual fate of a subagent's worktree-agent-* branch) looks like "commits with no PR" (#755).
    # Parking it would open a draft PR that duplicates main. Its own PR, merged or open, still decides.
    if ($Class -notin @('merged', 'in-review')) {
        if ($Containment -eq 'contained' -and $Dirty -eq 'clean' -and $CommitsAhead -gt 0) {
            return (& $mk 'delete-contained' $true 'its content is already on the default branch (merged through another PR) - branch and worktree removed')
        }
        # Only a hint, so a human decides: deleting on a heuristic could lose the one commit it missed.
        # Never over uncommitted changes (they cannot be on main: wip-park saves them first), and
        # never for merged-advanced: commits after its own PR merged are new work by definition.
        if ($SupersededBy -and $Dirty -eq 'clean' -and $Class -ne 'merged-advanced') {
            return (& $mk 'needs-decision' $false "likely superseded by $SupersededBy - its work seems to be on the default branch already; check that its newest commits are there too, then delete the branch instead of parking a duplicate PR")
        }
    }
    if ($Class -eq 'closed-unmerged') {
        return (& $mk 'needs-decision' $false 'its PR was closed without merging - reopen it or discard the branch')
    }
    if ($Dirty -eq 'dirty') {
        return (& $mk 'wip-park' $true 'uncommitted changes - committed as WIP and parked as a draft PR')
    }
    switch ($Class) {
        'merged'          { return (& $mk 'teardown' $true 'its PR is merged at this tip - branch and worktree removed') }
        'merged-advanced' { return (& $mk 'park' $true 'commits after its PR merged - parked as a new draft PR') }
        'in-review'       {
            # Archiving removes the session's worktree, so commits the PR does not have yet must be
            # pushed first - the open PR then picks them up (no new PR is created).
            if ($Unpushed -lt 0) { return (& $mk 'needs-decision' $false 'its PR is open, but I could not tell whether the branch has commits not pushed yet') }
            if ($Unpushed -gt 0) { return (& $mk 'park' $true "its PR is open, with $Unpushed commit(s) not pushed yet - pushed to the PR") }
            return (& $mk 'keep-review' $true 'its PR is open - already visible, nothing to do')
        }
    }
    if ($CommitsAhead -lt 0) {
        return (& $mk 'needs-decision' $false 'could not count its commits against the default branch')
    }
    if ($CommitsAhead -eq 0) {
        return (& $mk 'delete-empty' $true 'no commits and no changes - nothing to lose')
    }
    return (& $mk 'park' $true "$CommitsAhead commit(s) with no PR - parked as a draft PR")
}

# Is the branch's content already on the default branch? PURE: the result of
# `git merge-tree --write-tree <default> <branch>` comes in as arguments (#755).
#   contained - merges cleanly and the tree it writes IS the default branch's tree: it adds nothing
#   adds      - merges cleanly and brings something new
#   conflict  - the merge conflicts (exit 1): what work squashed into main and then edited further looks like
#   unknown   - merge-tree could not run (git older than 2.38, a missing ref)
function Get-SweepContainment {
    param([int]$ExitCode, [string[]]$Output = @(), [string]$DefaultTree = '')
    if ($ExitCode -eq 1) { return 'conflict' }
    if ($ExitCode -ne 0 -or -not $DefaultTree) { return 'unknown' }
    $tree = "$(@($Output)[0])".Trim()
    if ($tree -notmatch '^[0-9a-f]{40,64}$') { return 'unknown' }
    if ($tree -eq $DefaultTree.Trim()) { return 'contained' }
    return 'adds'
}

# The paths `git check-attr merge` gives a custom merge driver. PURE. Its lines read
# "path: merge: value"; unspecified / set / unset are git's own text and binary merges.
function Get-SweepDrivenPaths {
    param([string[]]$CheckAttr = @())
    return @(foreach ($l in $CheckAttr) {
        if ("$l" -match '^(.*): merge: (.*)$' -and $Matches[2].Trim() -notin @('unspecified', 'set', 'unset')) { $Matches[1] }
    })
}

# The issue and PR numbers a branch talks about: its issue-NNN name and every #NNN of its commit subjects.
# Not "owner/repo#12" (another repo's number) nor "C#12".
function Get-SweepIssueRefs {
    param([string]$Branch = '', [string[]]$Subjects = @())
    $n = @()
    if ($Branch -match '^issue-(\d+)') { $n += [int]$Matches[1] }
    foreach ($s in $Subjects) { foreach ($m in [regex]::Matches("$s", '(?<![\w/.-])#(\d+)\b')) { $n += [int]$m.Groups[1].Value } }
    return @($n | Select-Object -Unique)
}

# One referenced number, from GitHub's issueOrPullRequest node. PURE.
# Returns { Number; Done; By }: Done = a merged PR already did it - the number IS that PR, or it is
# an issue closed by one; By = that PR's number.
function ConvertTo-SweepRefState {
    param([int]$Number, $Node)
    $mk = { param($done, $by) [pscustomobject]@{ Number = $Number; Done = $done; By = $by } }
    if (-not $Node) { return (& $mk $false 0) }
    if ("$($Node.__typename)" -eq 'PullRequest') { return (& $mk ([bool]$Node.merged) $Number) }
    if ("$($Node.state)" -ne 'CLOSED') { return (& $mk $false 0) }
    $pr = @($Node.closedByPullRequestsReferences.nodes | Where-Object { $_.merged }) | Select-Object -First 1
    if ($pr) { return (& $mk $true ([int]$pr.number)) }
    return (& $mk $false 0)
}

# Is this branch's work probably already on the default branch through another PR? PURE.
# A HINT, never proof: the caller turns it into a decision, not a deletion. '#N' text, or ''.
#   - its own PR was closed with "superseded by #N" (in the body or a comment); or
#   - it no longer merges cleanly AND every issue/PR it references was done by a merged PR.
# A clean merge that adds something is left alone: that is what new, unparked work looks like.
function Get-SweepSupersededHint {
    param([string]$Containment = '', [object[]]$Refs = @(), [string[]]$PrComments = @(), [string]$Repo = '')
    # "#749" or the full PR URL - the comment that closed #748 in this repo used the URL. A URL counts
    # only when it is THIS repo's PR: another repo's #749 says nothing about this branch.
    $url = if ($Repo) { "https?://github\.com/$([regex]::Escape($Repo))/pull/" } else { '(?!)' }
    foreach ($c in $PrComments) { if ("$c" -match "(?i)superseded\s+by\s+(?:(?<![\w/.-])#|$url)(\d+)\b") { return "#$($Matches[1])" } }
    if ($Containment -ne 'conflict') { return '' }
    $all = @($Refs | Where-Object { $_ })
    if ($all.Count -eq 0 -or @($all | Where-Object { -not $_.Done }).Count -gt 0) { return '' }
    return (@($all | ForEach-Object { "#$($_.By)" } | Select-Object -Unique) -join ', ')
}

# A timestamp as UTC, or $null. ConvertFrom-Json already turns an ISO string into a DateTime, and
# stringifying that DateTime uses the CURRENT culture - on es-CO "09/10/2026", which a re-parse
# reads day-first, turning 10 September into 9 October. So a DateTime is used as it is, and a
# string is parsed culture-invariantly, round-trip.
function ConvertTo-SweepUtc {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq 'Unspecified') { return [datetime]::SpecifyKind($Value, 'Utc') }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    try {
        return [datetime]::Parse("$Value", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch { return $null }
}

# May this host-app session be archived? PURE: the filesystem is asked through two injected
# scriptblocks so the rules are testable without one.
# Returns { SessionId; Title; Archive; Reason; Branch }.
function Get-SweepArchiveVerdict {
    param(
        $Session,
        [object[]]$Items = @(),
        [string[]]$ScannedRoots = @(),
        [int]$IdleDays = 7,
        [datetime]$Now = (Get-Date),
        [scriptblock]$IsGitRepo  = { param($p) [bool](git -C $p rev-parse --git-dir 2>$null) },
        [scriptblock]$PathExists = { param($p) Test-Path -LiteralPath $p }
    )
    $mk = { param($ok, $why, $branch = '')
        [pscustomobject]@{ SessionId = "$($Session.sessionId)"; Title = "$($Session.title)"; Archive = $ok; Reason = $why; Branch = $branch } }

    if ($Session.isRunning) { return (& $mk $false 'still running') }
    if ($Session.pinned)    { return (& $mk $false 'pinned') }

    $cwd = ConvertTo-SweepPath $Session.cwd
    $idle = $IdleDays
    $last = ConvertTo-SweepUtc $Session.lastActivityAt
    if ($last) { $idle = ($Now.ToUniversalTime() - $last).TotalDays }
    $idleEnough = ($idle -ge $IdleDays)

    # The branch whose worktree IS this folder decides.
    $item = @($Items | Where-Object { $_.WorktreePath -and (ConvertTo-SweepPath $_.WorktreePath) -eq $cwd }) | Select-Object -First 1
    if ($item) {
        if ($item.Resolved) { return (& $mk $true "$($item.Action): $($item.Reason)" $item.Branch) }
        return (& $mk $false $item.Reason $item.Branch)
    }

    $root = @($ScannedRoots | Where-Object { $r = ConvertTo-SweepPath $_; $cwd -eq $r -or $cwd.StartsWith("$r\") }) | Select-Object -First 1
    if ($root) {
        # Inside a scanned repo but not on one of its work branches: the repo root on its default
        # branch, or a worktree that is already gone. Neither holds work of its own.
        if ($cwd -ne (ConvertTo-SweepPath $root) -and -not (& $PathExists $Session.cwd)) {
            return (& $mk $true 'its worktree no longer exists - no work left behind')
        }
        if ($idleEnough) { return (& $mk $true "no branch of its own, idle $([int]$idle) day(s)") }
        return (& $mk $false "recent (idle $([int]$idle) of $IdleDays day(s))")
    }

    # A folder that is gone holds no work: whatever branch it had lives on in its repo, and that
    # repo's branches get their own disposition above.
    if (-not (& $PathExists $Session.cwd)) { return (& $mk $true 'its folder no longer exists - no work left behind') }
    if (& $IsGitRepo $Session.cwd) {
        return (& $mk $false 'its repo was not scanned - its pending work is unknown (widen -Root)')
    }
    if ($idleEnough) { return (& $mk $true "outside any repo, idle $([int]$idle) day(s)") }
    return (& $mk $false "recent (idle $([int]$idle) of $IdleDays day(s))")
}

# Which host sessions this run may even look at. PURE (the filesystem comes in as scriptblocks).
#   repo    - the sessions of THIS repo: its root, its worktrees, and worktrees of it that are gone.
#             The default, so a sweep run in one repo never reaches into another one.
#   orphans - sessions no existing repo owns: their folder is gone, or it is outside any repo.
#             Never a session of an existing repo - that one belongs to its repo's own sweep.
#   all     - every session.
function Select-SweepSessions {
    param(
        [object[]]$Sessions = @(),
        [ValidateSet('repo', 'orphans', 'all')][string]$Scope = 'repo',
        [string]$RepoRoot = '',
        [scriptblock]$MainRepoOf = { param($p) '' },
        [scriptblock]$PathExists = { param($p) Test-Path -LiteralPath $p }
    )
    if ($Scope -eq 'all') { return @($Sessions) }
    $root = ConvertTo-SweepPath $RepoRoot
    return @($Sessions | Where-Object {
        $cwd = ConvertTo-SweepPath $_.cwd
        $exists = [bool](& $PathExists $_.cwd)
        $main = if ($exists) { ConvertTo-SweepPath (& $MainRepoOf $_.cwd) } else { '' }
        if ($Scope -eq 'repo') {
            ($root -and ($main -eq $root -or $cwd -eq $root -or $cwd.StartsWith("$root\.claude\worktrees\")))
        } else {
            $insideGoneWorktree = (-not $exists -and $cwd -match '\\\.claude\\worktrees\\' -and (& $PathExists (($_.cwd -replace '[\\/]\.claude[\\/]worktrees[\\/].*$', ''))))
            ((-not $exists) -and -not $insideGoneWorktree) -or ($exists -and -not $main)
        }
    })
}

# Body of the draft PR that parks a branch. `Refs`, never a closing keyword: a parked PR is not
# done work, and a closing keyword would close the issue the day someone merges it by accident.
function New-ParkedPrBody {
    param([string]$Branch, [string]$Reason, [string]$SessionTitle = '', [string]$SessionLink = '')
    $lines = @(
        'Parked by `/cleanup sessions` so the default branch knows this work exists.'
        ''
        "- Branch: ``$Branch``"
        "- Why: $Reason"
    )
    if ($SessionTitle -or $SessionLink) {
        $s = if ($SessionTitle -and $SessionLink) { "[$SessionTitle]($SessionLink)" } elseif ($SessionLink) { $SessionLink } else { $SessionTitle }
        $lines += "- Session that worked it: $s"
    }
    if ($Branch -match '^issue-(\d+)') { $lines += "- Refs #$($Matches[1])" }
    $lines += ''
    $lines += 'Draft on purpose: nothing here is reviewed yet. To resume it, run `/board work` - parked work is listed there - or check out the branch; mark the PR ready when it is.'
    return ($lines -join "`n")
}

# Is this branch provably contained in origin's default branch? (#755) Defined above the dot-source
# guard so the tests run it on a real repo; defining it touches nothing.
# Run inside the repo. `merge-tree --write-tree` merges in memory: no worktree, index or ref changes.
# Fully qualified refs: a short name can resolve to a local branch called "origin/main" or to a tag
# named like the branch, and the proof would then be about a different commit than `branch -D` deletes.
function Get-BranchContainment([string]$Default, [string]$Branch) {
    $base = "refs/remotes/origin/$Default"; $head = "refs/heads/$Branch"
    $dt = (git rev-parse --verify --quiet "$base^{tree}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $dt) { return 'unknown' }
    # merge-tree also exits 1 on a ref it cannot read, which would read as "conflict".
    $null = (git rev-parse --verify --quiet "$head^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    $out = @(git merge-tree --write-tree $base $head 2>$null)
    $c = Get-SweepContainment -ExitCode $LASTEXITCODE -Output $out -DefaultTree "$dt"
    if ($c -ne 'contained') { return $c }
    # merge-tree honours the repo's merge drivers: a `merge=ours` file merges "cleanly" to main's side
    # and would look contained while the branch's change is on main nowhere. For the paths the branch
    # changed that have a custom driver - and only those: main editing a file after the squash is the
    # usual case and merges correctly - the deletion needs the plain proof that main has the same file.
    $mb = (git merge-base $base $head 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $mb) { return 'unknown' }
    $q = @('-c', 'core.quotePath=false')
    $mine = @(git @q diff --no-renames --name-only "$mb" $head 2>$null | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    if ($mine.Count -eq 0) { return 'contained' }
    # Attributes can come from the working tree, either side's tree, info/attributes or core.attributesFile.
    # Paths go as arguments, in batches under Windows' command-line limit: piped into git on Windows
    # every line arrives with a trailing CR, and "f.txt`r" matches no attribute pattern.
    $driven = @()
    foreach ($src in @('', $base, $head)) {
        # Built as an array on purpose: `if` would unroll a one-item array to a string, and a string
        # splatted into git does not arrive as one argument.
        $sa = @(); if ($src) { $sa = @("--source=$src") }
        for ($i = 0; $i -lt $mine.Count; $i += 200) {
            $batch = @($mine[$i..([math]::Min($i + 199, $mine.Count - 1))])
            $attr = @(git @q check-attr @sa merge -- @batch 2>$null)
            if ($LASTEXITCODE -ne 0) { return 'unknown' }
            $driven += @(Get-SweepDrivenPaths -CheckAttr $attr)
        }
    }
    $driven = @($driven | Select-Object -Unique)
    if ($driven.Count -eq 0) { return 'contained' }
    $null = (git @q --literal-pathspecs diff --quiet --no-renames $base $head -- @driven 2>$null)
    switch ($LASTEXITCODE) { 0 { return 'contained' } 1 { return 'adds' } default { return 'unknown' } }
}

# Dot-source guard: with $env:ABIOS_SWEEP_DOTSOURCE set, return after defining the pure helpers
# WITHOUT touching disk, git, gh or the token.
if ($env:ABIOS_SWEEP_DOTSOURCE) { return }

# ------------------------------------------------------------- live (side-effecting)

. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
. (Join-Path $PSScriptRoot 'PluginState.ps1')
# Liveness of a Claude process reuses the recycled-pid rule in Board-Work.ps1; its param() block
# would reset any shared parameter name here, so what the caller passed is replayed afterwards.
$script:PrevDotSource = $env:ABIOS_BOARDWORK_DOTSOURCE
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
try   { . (Join-Path $PSScriptRoot 'Board-Work.ps1') }
finally {
    $env:ABIOS_BOARDWORK_DOTSOURCE = $script:PrevDotSource
    foreach ($k in $PSBoundParameters.Keys) { Set-Variable -Name $k -Value $PSBoundParameters[$k] -Scope Local }
}

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = $(. (Join-Path $PSScriptRoot 'Get-AbiosAccounts.ps1'); Get-AbiosTokenValue -VarName $TokenVar -AllowAmbient:(-not $PSBoundParameters.ContainsKey('TokenVar'))) }
if (-not $env:GH_TOKEN) { throw "No GitHub token: $TokenVar is unset, GH_TOKEN is empty and gh has no stored login. Run 'gh auth login', or map the account with /board setup." }

$doctor = Join-Path $PSScriptRoot 'Board-Doctor.ps1'
if ($Owner.Count -eq 0) {
    $me = "$(Invoke-Gh -GhArgs @('api', 'user', '--jq', '.login') -What 'read the token login (to know which repos are yours; or pass -Owner)')".Trim()
    if (-not $me) { throw "Could not read the token's login to know which repos are yours. Pass -Owner <account>." }
    $Owner = @($me)
}
$now = (Get-Date).ToUniversalTime()

# --- which repos --------------------------------------------------------------
# The main checkout of the repo a folder belongs to, or '' - a worktree resolves to the repo it
# was cut from (its common git dir), so a session in .claude/worktrees/x scans the whole repo.
function Get-MainRepoRoot([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $common = (git -C $Path rev-parse --path-format=absolute --git-common-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $common) { return '' }
    if ((Split-Path $common -Leaf) -ne '.git') { return '' }   # bare or unusual layout: not ours to sweep
    return (Resolve-Path -LiteralPath (Split-Path $common -Parent)).Path
}

# Every session is read (a running one anywhere must still veto its branch), but only the ones
# in -Scope are judged for archiving.
$allSessions = @()
if ($HostSessionsFile) { $allSessions = @(Get-Content -LiteralPath $HostSessionsFile -Raw | ConvertFrom-Json) }
$here = Get-MainRepoRoot (Get-Location).Path
if ($Scope -eq 'repo' -and -not $here) { throw "Not inside a git repository. Run it from the repo to clean, or use -Scope orphans / -Scope all." }
$hostSessions = @(Select-SweepSessions -Sessions $allSessions -Scope $Scope -RepoRoot $here `
    -MainRepoOf { param($p) Get-MainRepoRoot $p })

$repoRoots = @()
switch ($Scope) {
    'repo'    { $repoRoots = @($here) }
    'orphans' { $repoRoots = @() }   # no repo is touched: these sessions belong to none
    'all' {
        foreach ($r in @($Root | Where-Object { $_ })) {
            foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction Stop)) {
                if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { $repoRoots += $d.FullName }
            }
        }
        # Every repo a session lives in is swept too - otherwise its session could only ever be kept
        # as "pending work unknown", which is the pile this command exists to empty.
        foreach ($s in $allSessions) { $m = Get-MainRepoRoot "$($s.cwd)"; if ($m) { $repoRoots += $m } }
        if ($here) { $repoRoots += $here }
    }
}
$seen = @{}
$repoRoots = @(foreach ($r in $repoRoots) { $k = ConvertTo-SweepPath $r; if (-not $seen[$k]) { $seen[$k] = $true; $r } })

# --- which sessions are open --------------------------------------------------
$openPaths = @($allSessions | Where-Object { $_.isRunning } | ForEach-Object { ConvertTo-SweepPath $_.cwd })
foreach ($s in @((Read-ClaudeSessions).Sessions)) {
    # 'unknown' liveness counts as open: a session we cannot prove dead is not swept.
    if ((Get-HolderLiveness -ProcessId $s.Pid -StartFt $s.ProcStart) -ne 'dead') { $openPaths += (ConvertTo-SweepPath $s.Cwd) }
}
$openPaths = @($openPaths | Where-Object { $_ } | Select-Object -Unique)

# --- already on the default branch? (#755) ------------------------------------
# The superseded hint of one branch. A hint that cannot be read is no hint: the branch then gets
# the disposition it had before #755 (park), never a deletion.
$refCache = @{}
function Get-BranchSupersededHint([string]$Repo, [string]$Default, $Branch, [string]$Containment) {
    try {
        $texts = @()
        if ($Branch.Class -eq 'closed-unmerged' -and $Branch.Pr) {
            $pr = Invoke-Gh -GhArgs @('pr', 'view', "$($Branch.Pr)", '--repo', $Repo, '--json', 'body,comments') -Json -What "read PR #$($Branch.Pr)"
            $texts = @("$($pr.body)") + @($pr.comments | ForEach-Object { "$($_.body)" })
        }
        $refs = @()
        if ($Containment -eq 'conflict') {
            $subjects = @(git log --format=%s "refs/remotes/origin/$Default..refs/heads/$($Branch.Branch)" 2>$null)
            if ($LASTEXITCODE -ne 0) { return '' }   # a partial reference list would make a false hint
            $o, $name = $Repo -split '/', 2
            $q = 'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issueOrPullRequest(number:$n){__typename ... on Issue{state closedByPullRequestsReferences(first:10,includeClosedPrs:true){nodes{number merged}}} ... on PullRequest{merged}}}}'
            foreach ($n in (Get-SweepIssueRefs -Branch $Branch.Branch -Subjects $subjects)) {
                $key = "$Repo#$n"
                if (-not $refCache.ContainsKey($key)) {
                    $resp = Invoke-Gh -GhArgs @('api', 'graphql', '-f', "query=$q", '-f', "o=$o", '-f', "r=$name", '-F', "n=$n") -Graphql -What "read #$n"
                    $refCache[$key] = ConvertTo-SweepRefState -Number $n -Node $resp.data.repository.issueOrPullRequest
                }
                $refs += $refCache[$key]
            }
        }
        return (Get-SweepSupersededHint -Containment $Containment -Refs $refs -PrComments $texts -Repo $Repo)
    } catch { return '' }
}

# --- plan ---------------------------------------------------------------------
$items = @(); $skippedRepos = @()
foreach ($rr in $repoRoots) {
    Push-Location -LiteralPath $rr
    try {
        $repo = $null
        try { $repo = Get-RepoFromOrigin } catch { }
        if (-not $repo) { $skippedRepos += [pscustomobject]@{ Path = $rr; Reason = 'no GitHub origin' }; continue }
        # A repo the token cannot read (a business repo under a personal token) makes the doctor
        # throw. That repo is skipped, never swept blind.
        $raw = $null
        try { $raw = & $doctor -Repo $repo -Json 6>$null } catch {
            $skippedRepos += [pscustomobject]@{ Path = $rr; Reason = "branch inventory failed ($repo): $($_.Exception.Message -replace '\s+', ' ')" }; continue
        }
        if ($LASTEXITCODE -ne 0 -or -not $raw) { $skippedRepos += [pscustomobject]@{ Path = $rr; Reason = "branch inventory failed ($repo)" }; continue }
        $inv = ($raw -join "`n") | ConvertFrom-Json
        $default = ''
        try { $default = ((git symbolic-ref --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', '') } catch { }
        if (-not $default) { $default = 'main' }
        $repoOwner = ($repo -split '/')[0]
        $foreign = if ($Owner -contains $repoOwner) { '' } else { $repoOwner }
        foreach ($b in @($inv.branches)) {
            $ahead = -1
            $n = (git rev-list --count "origin/$default..$($b.Branch)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and "$n" -match '^\d+$') { $ahead = [int]$n }
            $unpushed = 0
            if ($b.Class -eq 'in-review') {
                $unpushed = -1
                $u = (git rev-list --count "origin/$($b.Branch)..$($b.Branch)" 2>$null)
                if ($LASTEXITCODE -eq 0 -and "$u" -match '^\d+$') { $unpushed = [int]$u }
            }
            $wt = "$($b.WorktreePath)"
            $open = [bool]($wt -and ($openPaths -contains (ConvertTo-SweepPath $wt)))
            # Only a branch that would otherwise be parked or left as closed-unmerged is measured:
            # the git and gh reads cost nothing on the rest.
            $containment = ''; $superseded = ''
            if ($ahead -gt 0 -and $b.Class -notin @('merged', 'in-review', 'active') -and -not $open -and -not $b.HasLiveSession) {
                $containment = Get-BranchContainment -Default $default -Branch $b.Branch
                if ($containment -ne 'contained') { $superseded = Get-BranchSupersededHint -Repo $repo -Default $default -Branch $b -Containment $containment }
            }
            $a = Get-SweepItemAction -Class $b.Class -Dirty "$($b.Dirty)" -HasLiveSession ([bool]$b.HasLiveSession) `
                -SessionOpen $open -CommitsAhead $ahead -ForeignOwner $foreign -Unpushed $unpushed `
                -Containment $containment -SupersededBy $superseded
            $items += [pscustomobject]@{
                Repo = $repo; RepoRoot = $rr; DefaultBranch = $default; Branch = $b.Branch; Class = $b.Class
                Pr = $b.Pr; WorktreePath = $wt; CommitsAhead = $ahead
                Action = $a.Action; Resolved = $a.Resolved; Reason = $a.Reason; Outcome = 'planned'
            }
        }
    } finally { Pop-Location }
}

# --- execute (git side) -------------------------------------------------------
function Set-Failed($Item, [string]$Why) { $Item.Resolved = $false; $Item.Outcome = 'failed'; $Item.Reason = "$($Item.Reason) - FAILED: $Why" }

function Find-HostSession([string]$WorktreePath) {
    if (-not $WorktreePath) { return $null }
    $p = ConvertTo-SweepPath $WorktreePath
    return (@($hostSessions | Where-Object { (ConvertTo-SweepPath $_.cwd) -eq $p }) | Select-Object -First 1)
}

if ($Force) {
    $labelled = @{}
    foreach ($grp in ($items | Group-Object RepoRoot)) {
        Push-Location -LiteralPath $grp.Name
        try {
            $repo = $grp.Group[0].Repo
            foreach ($it in $grp.Group) {
                try {
                    if ($it.Action -eq 'wip-park') {
                        $p = if ($it.WorktreePath) { $it.WorktreePath } else { $grp.Name }
                        git -C $p add -A 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Set-Failed $it 'git add'; continue }
                        git -C $p commit -q -m "wip: parked by close-cycle --all" 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Set-Failed $it 'git commit (a hook may have refused it)'; continue }
                    }
                    if ($it.Action -in @('park', 'wip-park')) {
                        git push -q -u origin $it.Branch 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Set-Failed $it 'git push'; continue }
                        # Invoke-Gh throws on any gh failure, so an unreadable PR list is a failed
                        # step (caught below), never "no PR yet" followed by a duplicate PR.
                        $openPr = @(Invoke-Gh -GhArgs @('pr', 'list', '--repo', $repo, '--head', $it.Branch, '--state', 'open', '--json', 'number') -Json -What "list the open PRs of $($it.Branch)")
                        if ($openPr.Count -eq 0) {
                            if (-not $labelled[$repo]) {
                                $null = Invoke-Gh -GhArgs @('label', 'create', 'parked', '--repo', $repo, '--color', 'BFD4F2', '--description', 'Work parked by close-cycle --all: pushed, draft PR, not merged', '--force') -What "create the parked label in $repo"
                                $labelled[$repo] = $true
                            }
                            $hs = Find-HostSession $it.WorktreePath
                            $body = New-ParkedPrBody -Branch $it.Branch -Reason $it.Reason -SessionTitle "$($hs.title)" -SessionLink "$($hs.link)"
                            $url = Invoke-Gh -GhArgs @('pr', 'create', '--repo', $repo, '--draft', '--base', $it.DefaultBranch, '--head', $it.Branch, '--title', "WIP (parked): $($it.Branch)", '--body', $body, '--label', 'parked') -What "open the draft PR of $($it.Branch)"
                            $it.Pr = "$(@($url) | Select-Object -Last 1)".Trim()
                        }
                        $it.Outcome = 'done'
                    } elseif ($it.Action -in @('delete-empty', 'delete-contained')) {
                        if ($it.WorktreePath -and (ConvertTo-SweepPath $it.WorktreePath) -eq (ConvertTo-SweepPath $grp.Name)) {
                            Set-Failed $it 'it is checked out in the main folder - switch it to the default branch first'; continue
                        }
                        # `branch -D` skips git's own merged check, so containment is proven again
                        # right before it: a commit made since the plan must not go with the branch.
                        if ($it.Action -eq 'delete-contained' -and (Get-BranchContainment -Default $it.DefaultBranch -Branch $it.Branch) -ne 'contained') {
                            Set-Failed $it 'the branch is no longer contained in the default branch - re-run the plan'; continue
                        }
                        if ($it.WorktreePath -and (Test-Path -LiteralPath $it.WorktreePath)) {
                            git worktree remove $it.WorktreePath 2>&1 | Out-Null
                            if ($LASTEXITCODE -ne 0) { Set-Failed $it 'git worktree remove'; continue }
                        }
                        git branch -D $it.Branch 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { Set-Failed $it 'git branch -D'; continue }
                        $it.Outcome = 'done'
                    } elseif ($it.Action -eq 'keep-review') {
                        $it.Outcome = 'done'
                    }
                } catch { Set-Failed $it "$_" }
            }
            # Proven-merged branches go through the doctor's own -Auto path: the one class it deletes
            # unattended, with its dirty-worktree and current-worktree guards. Branches with an open
            # session are protected so they survive even if their state changed since the plan.
            $tear = @($grp.Group | Where-Object Action -eq 'teardown')
            if ($tear.Count -gt 0) {
                $protect = @($grp.Group | Where-Object Action -eq 'skip-open' | ForEach-Object Branch)
                & $doctor -Repo $repo -Fix -Auto -Protect $protect 6>$null | Out-Null
                foreach ($it in $tear) {
                    $still = (git rev-parse --verify --quiet "refs/heads/$($it.Branch)" 2>$null)
                    if ($still) { Set-Failed $it 'the branch is still there after the doctor pass' } else { $it.Outcome = 'done' }
                }
            }
        } finally { Pop-Location }
    }
}

# --- archive verdicts (after the git side, so a failure keeps the session) -----
# A skipped repo is NOT scanned: counting it would read "no items" as "no pending work" and archive
# the sessions of a repo nobody looked at.
$skippedKeys = @($skippedRepos | ForEach-Object { ConvertTo-SweepPath $_.Path })
$scannedRoots = @($repoRoots | Where-Object { $skippedKeys -notcontains (ConvertTo-SweepPath $_) })
$verdicts = @(foreach ($s in $hostSessions) {
    Get-SweepArchiveVerdict -Session $s -Items $items -ScannedRoots $scannedRoots -IdleDays $IdleDays -Now $now
})

# --- report -------------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        generatedAt = $now.ToString('o'); executed = [bool]$Force; idleDays = $IdleDays
        repos = @($repoRoots); skippedRepos = @($skippedRepos)
        items = @($items)
        archive = @($verdicts | Where-Object Archive | Select-Object SessionId, Title, Reason, Branch)
        keep    = @($verdicts | Where-Object { -not $_.Archive } | Select-Object SessionId, Title, Reason, Branch)
    } | ConvertTo-Json -Depth 6
    exit 0
}

$labels = [ordered]@{
    'teardown' = 'Merged: branch and worktree deleted'; 'park' = 'Unmerged commits: push + draft PR (parked)'
    'wip-park' = 'Uncommitted changes: WIP commit + draft PR (parked)'; 'keep-review' = 'Open PR: left alone'
    'delete-empty' = 'Empty: deleted (no work on them)'
    'delete-contained' = 'Already on the default branch (merged through another PR): deleted'; 'needs-decision' = 'Need your decision'; 'skip-open' = 'A session is working: left alone'
}
$mode = if ($Force) { 'EXECUTED' } else { 'PLAN - nothing changed' }
Write-Host ""
Write-Host "=== /cleanup sessions  ($mode) ===" -ForegroundColor Cyan
Write-Host "    $($repoRoots.Count) repo(s), $($items.Count) branch(es), $($hostSessions.Count) app session(s)" -ForegroundColor DarkGray
foreach ($k in $labels.Keys) {
    $grp = @($items | Where-Object Action -eq $k)
    if ($grp.Count -eq 0) { continue }
    Write-Host ""
    Write-Host "--- $($labels[$k]) ($($grp.Count)) ---" -ForegroundColor Yellow
    foreach ($it in $grp) {
        $tag = if ($it.Outcome -eq 'failed') { '  [FAILED]' } else { '' }
        Write-Host ("   {0,-28} {1,-40} {2}{3}" -f (Split-Path $it.RepoRoot -Leaf), $it.Branch, $it.Reason, $tag)
    }
}
foreach ($s in $skippedRepos) { Write-Host ("   skipped: {0} ({1})" -f $s.Path, $s.Reason) -ForegroundColor DarkGray }
if ($hostSessions.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Sessions to archive ($(@($verdicts | Where-Object Archive).Count)) ---" -ForegroundColor Green
    foreach ($v in @($verdicts | Where-Object Archive)) { Write-Host ("   {0,-45} {1}" -f $v.Title, $v.Reason) }
    Write-Host "--- Sessions kept ($(@($verdicts | Where-Object { -not $_.Archive }).Count)) ---" -ForegroundColor DarkGray
    foreach ($v in @($verdicts | Where-Object { -not $_.Archive })) { Write-Host ("   {0,-45} {1}" -f $v.Title, $v.Reason) -ForegroundColor DarkGray }
}
Write-Host ""
if (-not $Force) { Write-Host "Plan only. Run with -Force to execute it." -ForegroundColor Yellow }
exit 0
