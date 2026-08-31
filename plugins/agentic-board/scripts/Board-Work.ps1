<#
.SYNOPSIS
    Show pending work across boards and start working an issue (single or parallel).

.DESCRIPTION
    Modes, designed for the /board work flow:

      1. -ListBoards [-Repo <owner/name>]
         Lists boards with their pending count (items in Backlog or no Status),
         so the user can pick which board to work from. Without -Repo it
         lists EVERY board of the owner (backups excluded); with -Repo it
         lists only the boards LINKED to that repository (repository.projectsV2),
         which is the "current repo" scope of the /board work flow.

      2. -ProjectNum <n>
         Lists the PENDING items of that board (Status = Backlog or empty),
         sorted by Priority (P0 first, empty last), with issue number, title,
         Priority, Size and Type. Draft notes are flagged (convert them with
         /board fill before starting them).

      3. -ProjectNum <n> -Start <issueNum>
         Starts working that issue: moves the board item to "In Progress",
         assigns the owner, and prints the full issue context (labels,
         body, sub-issues) so the agent can begin working it in-session.
         Supports -DryRun to preview without mutating.

      5. -ProjectNum <n> -Parallel <issueNums>
         Batch-start SEVERAL independent issues at once. For each issue it
         runs the same start logic as mode 3 (In Progress + assign + claim)
         but ALWAYS in its own isolated git worktree, each branched off the
         freshly fetched default branch. Add -Launch to open one visible
         Claude session per worktree (a Windows Terminal tab when 'wt' exists,
         else a standalone pwsh window), each briefed to work its own issue
         end-to-end. -DryRun plans the whole batch (and previews the launch
         commands) without mutating the board, touching git, or spawning
         anything. Blocked / claimed / closed issues are skipped with a reason,
         never aborting the batch.

    Branch-drift guard: on the read-only entry points (-Sessions and the pending
    listing) the flow warns - never blocks - when the current working copy's HEAD
    has drifted away from the branch this session started work on here (e.g. a
    foreign Stop hook ran `git checkout`/`git switch` mid-session). agentic-board'
    own hooks never switch branches; this only surfaces a move made from outside.

    Same conventions as Board-Fill.ps1: token from the Windows USER registry
    (unless GH_TOKEN is already set by gh-account), pure-ASCII source, and
    the board URL always printed at the end.

.PARAMETER Owner
    GitHub username that owns the boards. Defaults to CSalcedoDataBI.

.PARAMETER ListBoards
    Mode 1: list boards with pending counts (all of the owner, or only the
    ones linked to -Repo when given).

.PARAMETER Repo
    owner/name. With -ListBoards: restrict the listing to boards linked to
    this repository (the current-repo scope).

.PARAMETER ProjectNum
    GitHub Projects v2 number. Mode 2 alone, mode 3 with -Start.

.PARAMETER Start
    Issue number to start working (requires -ProjectNum).

.PARAMETER Parallel
    One or more issue numbers to batch-start, each in its own worktree
    (requires -ProjectNum). Mutually exclusive with -Start / -ToReview.

.PARAMETER Launch
    With -Parallel: after starting each worktree, spawn one visible Claude
    session per worktree (Windows Terminal tab, or a pwsh window as fallback),
    each briefed to work its own issue to a PR + review gate. With -DryRun it
    only previews the launch commands.

.PARAMETER Sessions
    Monitor mode: list the LIVE parallel-session fleet from
    .agentic-board/sessions.json (branch, worktree, launch method, and the
    PR opened for each branch). Dead-PID entries are pruned on read. Needs no
    -ProjectNum.

.PARAMETER ToReview
    Issue number to move into the "In Review" Status column (requires
    -ProjectNum). The work flow calls this after opening the PR: the change is
    now in review / testing while the gate runs. Errors if the board has no
    "In Review" option.

.PARAMETER DryRun
    With -Start / -Parallel / -ToReview: print what would change without executing.

.PARAMETER Branch
    With -Start: also create and checkout a work branch issue-<num>-<slug>
    (only when the current directory is a clone of the issue's repo).
    Finishing the work MUST then go through a PR with "Closes #<num>" so
    GitHub fills the Linked pull requests column on the board by itself.
    -Parallel always creates a branch (in a worktree), so -Branch is implied there.

.PARAMETER Base
    With -Start -Branch / -Parallel: the ref the new issue branch starts from.
    Defaults to the remote's default branch, freshly fetched (origin/main on this
    repo, but resolved rather than assumed) - never the current HEAD, which would drag
    the commits of whatever branch you happened to be standing on into the issue's PR
    (#294). Pass an explicit ref only for deliberately dependent work.

.PARAMETER BaseCurrent
    With -Start -Branch / -Parallel: base the issue branch on the CURRENT HEAD instead
    of the remote default - the opt-in for work that genuinely builds on the branch you
    are standing on. Mutually exclusive with -Base.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL;
    use GITHUB_TOKEN_BUSINESS for the PAL-Devs account.

.EXAMPLE
    .\Board-Work.ps1 -ListBoards
    .\Board-Work.ps1 -ListBoards -Repo CSalcedoDataBI/agentic-board
    .\Board-Work.ps1 -ProjectNum 13
    .\Board-Work.ps1 -ProjectNum 13 -Start 12 -DryRun
    .\Board-Work.ps1 -ProjectNum 13 -Start 12 -Branch
    .\Board-Work.ps1 -ProjectNum 13 -Parallel 12,14,15 -DryRun
    .\Board-Work.ps1 -ProjectNum 13 -Parallel 12,14,15
    .\Board-Work.ps1 -ProjectNum 13 -Parallel 12,14,15 -Launch
    .\Board-Work.ps1 -ProjectNum 13 -Parallel 12,14,15 -Launch -DryRun
    .\Board-Work.ps1 -Sessions
    .\Board-Work.ps1 -ProjectNum 13 -ToReview 12
#>
[CmdletBinding()]
param(
    [string]$Owner    = "CSalcedoDataBI",
    [switch]$ListBoards,
    [string]$Repo     = "",
    [int]   $ProjectNum = 0,
    [int]   $Start      = 0,
    # Accept as strings, not [int[]]: when the script is invoked via `pwsh -File`,
    # `-Parallel 129,130` arrives as the single string "129,130" (comma read as a
    # thousands separator -> 129130), NOT a 2-element array. Get-ParallelQueue
    # splits each token on ',' so both `-File` and native-array calls work.
    [string[]] $Parallel = @(),
    # Batch start (#633): several small, sequential sub-issues of the same epic share ONE
    # branch/worktree instead of each getting its own -Start cycle, so they close through ONE
    # PR/gate/merge. Same tolerant parsing as -Parallel (Get-ParallelQueue), for the same
    # `pwsh -File` flattening reason. Mutually exclusive with -Start and -Parallel: those are
    # two other, different ways of starting issues.
    [string[]] $StartGroup = @(),
    # Records this repo's standing answer to "one PR, or one per issue?" in
    # .agentic-board/config.json, so the preference survives the session instead of living in
    # the operator's head and being restated every time (#662). 'on' = always propose one PR
    # for the batch; 'off' = never propose grouping (each issue gets its own reviewable PR);
    # 'auto' = the default, propose it only where there is evidence the issues overlap.
    [ValidateSet('on', 'off', 'auto')]
    [string] $PreferGroupedPRs = '',
    [switch]$Launch,
    [switch]$Fleet,
    [switch]$Sessions,
    [switch]$Watch,
    [switch]$AutoClean,
    # Opt-in discard: let auto-clean delete a session branch even with unmerged commits
    # (default is the safe `git branch -d`, which keeps them and warns instead) - #273.
    [switch]$ForceDeleteBranch,
    # Opt-in discard: let auto-clean remove a session worktree that still holds uncommitted
    # or untracked files (default keeps it and warns instead) - #276.
    [switch]$ForceRemoveWorktree,
    [int]   $WatchPollSec    = 30,
    [int]   $WatchTimeoutSec = 1800,
    [int]   $ToReview   = 0,
    [int]   $Stop       = 0,
    [int]   $Relaunch   = 0,
    [int]   $Lock       = 0,
    [int]   $Unlock     = 0,
    # cerrar-ciclo: classify the CURRENT branch and route it to the right disposition (#302).
    [switch]$CloseLoop,
    [switch]$Reap,
    [switch]$KillAll,
    [switch]$Force,
    [int]   $MaxConcurrent = 0,
    [switch]$DryRun,
    [switch]$Branch,
    [string]$Base          = "",
    [switch]$BaseCurrent,
    [switch]$IgnoreBlocked,
    [switch]$TakeOver,
    # Irreversible brake (#440): brief the launched session to stop at a reviewed PR instead of
    # ordering the merge. Set by /expert auto when the contract marks `merge` as irreversible.
    # When neither -StopAtPR nor -AllowMerge is specified, Resolve-LaunchBrake brakes by default (#598).
    [switch]$StopAtPR,
    # Explicit opt-in to autonomous merging (#598). A launched session NEVER merges on its own
    # unless the human passes this flag — the default is to stop at a reviewed PR. Pass
    # -AllowMerge only when a fully autonomous close is intentional and the issue has been reviewed.
    [switch]$AllowMerge,
    # Path to the full brief for the launched session (e.g. .agentic-board/expert-brief-<n>.md),
    # which it is told to read first and treat as overriding the generic steps.
    [string]$BriefFile     = "",
    # The contract's irreversible action list, recorded in the brake marker so the mechanical
    # guard (#516) refuses exactly what this run's contract brakes on - no more, no less.
    # Empty with -StopAtPR falls back to the default vocabulary rather than arming nothing.
    [string[]]$Irreversible = @(),
    # The human ORDERED this run to finish end-to-end (#530). Travels with the instruction, not with
    # a setting on disk: it is recorded in the brake marker so the merge decision -- taken later,
    # when the facts exist -- still knows what was actually asked for.
    [switch]$EndToEnd,
    # The contract's time budget in minutes, recorded in the brake marker so the PreToolUse hook
    # can ENFORCE it (#564): past this, only wrap-up commands (handoff, commit/push, report) pass.
    # 0 = no budget enforcement.
    [int]$BudgetMinutes    = 0,
    [string]$TokenVar      = "GITHUB_TOKEN_PERSONAL",
    # Only a plain env-var identifier - it gets interpolated into the spawned
    # -Command string, so reject anything that could inject (';', quotes, spaces).
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string]$ClaudeAuthVar = "ANTHROPIC_API_KEY"
)

$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
# The canonical/legacy option vocabulary (issue #278): lets this script understand a
# board born from GitHub's default template ('Todo') as well as a canonical one.
. (Join-Path $PSScriptRoot 'Get-BoardVocabulary.ps1')
# gh fails closed (#303/#314): a non-zero exit OR an exit-0 graphql errors[] body must THROW,
# not read as an empty board or a write that silently no-op'd. Pure at load; dot-sourced before
# the guard so unit tests get the seam. Session-monitor reads deliberately stay best-effort.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Board reads that report their own truncation (#484). A capped item-list returns exit 0 and a
# SHORT list, which this script used to print as "sin pendientes" over a board full of Backlog.
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')
# owner/name resolver from origin (dot-safe regex) - cerrar-ciclo (#302) resolves the current repo.
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# Per-repo preferences (#662) - today: whether related issues should share one PR.
. (Join-Path $PSScriptRoot 'Get-BoardConfig.ps1')

# NOTE: the GH_TOKEN check lives in the main-entry guard below (after every function
# is defined) so the pure helpers can be dot-sourced for unit tests without a token
# and without side effects (set $env:ABIOS_BOARDWORK_DOTSOURCE=1 before dot-sourcing).

function Get-BoardUrl([int]$num) { "https://github.com/users/$Owner/projects/$num" }

# An item is PENDING when it has no Status yet, or its Status MEANS Backlog - in the
# canonical vocabulary or in a legacy one (GitHub's default template calls it 'Todo').
# Before #278 this compared to the literal "Backlog", so every item of a default-template
# board was invisible here and the script reported a board with dozens of open issues as
# having no pending work.
function Test-Pending($item) {
    if (-not $item.status) { return $true }
    (Get-CanonicalOptionName 'Status' $item.status) -eq 'Backlog'
}

# ------------------------------------------------------------------------------
# Grouped PRs (#662): finding the issues that would sensibly share one PR.
#
# The per-PR cycle - a review-gate run against the subscription quota, a
# second-opinion round when no real reviewer shows up, and a merge confirmation
# that costs the user's attention - is paid ONCE PER PR, not per issue. On a
# board of related issues that cost dominates the work itself. The machinery to
# avoid it (-StartGroup + a single PR closing several issues) already shipped
# with #633; what was missing is that nothing ever POINTS AT IT, so a session
# following the contract literally opens N PRs for N issues.
#
# These helpers only ever SUGGEST, and only off evidence they can name. A
# suggestion the user cannot check is worse than none: it asks them to trust a
# grouping whose reason is invisible, on the one decision (what lands in one
# reviewable PR) where the reason is the whole point.
# ------------------------------------------------------------------------------

# The tokens by which an issue can NAME a file of this repo.
#
# A file qualifies as evidence at all only when its stem is DISTINCTIVE: hyphenated and at
# least six characters. That gate applies to the whole file, not just to the bare stem - a
# non-qualifying file contributes no token, not even its full name with extension. This is
# deliberate, and it is what keeps the grouping honest. Run over this repo the rule excludes
# 73 names, and they are exactly the ones that would produce confident groupings with no
# basis: `board.md`, `bi.json`, `automation.md`, `413.md`, `.gitignore`. "Two issues both
# say board.md" is not a reason to put them in one PR. A hyphenated verb-noun name is not
# prose, and that is the whole distinction being drawn.
#
# A qualifying file contributes two tokens, both matched exactly:
#   * the file name with extension -> "Board-ReviewGate.ps1"
#   * the bare stem                -> "Board-ReviewGate"   (issues name scripts both ways)
function Get-RepoFileTokens {
    [CmdletBinding()]
    param([string[]]$Paths)

    $map = @{}
    foreach ($path in @($Paths)) {
        if (-not $path) { continue }
        $leaf = Split-Path -Leaf $path
        if (-not $leaf) { continue }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        if ($stem -notmatch '-') { continue }
        if ($stem.Length -lt 6)  { continue }
        $map[$leaf] = $leaf
        $map[$stem] = $leaf
    }
    $map
}

# Does $Text name $Token as a whole word? Anchored on both sides by a non-name
# character so "Board-Work" does not match inside "Board-Workspace".
function Test-NamesToken {
    [CmdletBinding()]
    param([string]$Text, [string]$Token)

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Token)) { return $false }
    $escaped = [regex]::Escape($Token)
    [bool]($Text -match "(?i)(^|[^A-Za-z0-9_.-])$escaped($|[^A-Za-z0-9_-])")
}

# An item can be batched only if it can be STARTED at all: a draft note has no issue
# to close, and a blocked one is refused by -StartGroup anyway. Offering either in a
# batch would produce a group that falls apart the moment the user accepts it.
function Test-Groupable($item) {
    if (-not $item) { return $false }
    if ($item.content.type -eq 'DraftIssue') { return $false }
    if (-not $item.content.number)           { return $false }
    if (@($item.labels) -contains 'blocked') { return $false }
    $true
}

# `owner/name` for a board item. This script handles items from BOTH readers and they do not
# agree on the shape: `Get-BoardItems` (gh project item-list) hands back `content.repository` as
# a plain string, while `Get-BoardItem` (GraphQL, used by the start path) nests it as
# `content.repository.nameWithOwner`. Grouping is fed by the first, but a caller reaching for
# the second must not silently produce one bucket named after a stringified object - that would
# merge every repo on the board back into a single group, which is the failure the partitioning
# exists to prevent, wearing the disguise of working code.
function Get-ItemRepoName {
    [CmdletBinding()]
    param($Item)

    $r = $Item.content.repository
    if (-not $r) { return '' }
    if ($r -is [string]) { return $r }
    if ($r.PSObject.Properties['nameWithOwner'] -and $r.nameWithOwner) { return [string]$r.nameWithOwner }
    [string]$r
}

# The suggestions themselves. Each carries the EVIDENCE that produced it, because that
# is what the user judges - not the tool's confidence.
#
#   reason 'file' - two or more pending issues name the same file of this repo. The
#                   strongest signal available before any code is written, and the one
#                   that best predicts a merge conflict between two separate branches.
#   reason 'area' - two or more share the board's Area field. Weaker (an area is a
#                   neighbourhood, not a file) but it is a human's own classification.
#
# An issue lands in at most ONE suggestion, file evidence winning, so the printed groups
# never overlap - two suggestions naming the same issue would be advice the user cannot
# act on twice.
function Get-GroupingSuggestions {
    [CmdletBinding()]
    param(
        [object[]] $Pending,
        [string[]] $RepoFiles = @(),
        # The repo this checkout IS. File evidence comes from its `git ls-files`, so it can only
        # speak about its own issues: a foreign-repo issue naming `Board-Work.ps1` is naming a
        # different file. Empty (outside a repo) disables the file signal entirely rather than
        # letting it match across repos it cannot see.
        [string]   $CurrentRepo = '',
        [int]      $MinGroup  = 2,
        # A group is only a saving if the PR it produces is still REVIEWABLE. Left uncapped,
        # this happily proposed eight issues in one PR against the real board - well past the
        # 600-line / 20-file threshold the review gate itself warns about, which trades a cost
        # the user pays knowingly (N review rounds) for one they do not (a PR nobody can read).
        # The overflow is never silently dropped: it is returned in `dropped` and printed.
        [int]      $MaxGroup  = 4
    )

    $items = @(@($Pending) | Where-Object { Test-Groupable $_ })
    if ($items.Count -lt $MinGroup) { return @() }

    $suggestions = @()

    # A single PR lives in ONE repo. `Closes #n` closes an issue of that same repo and nothing
    # else, and -StartGroup puts the whole batch on one branch in one checkout - so a group
    # spanning two repos is a batch that CANNOT be finished. It would start every issue in it,
    # move them to In Progress, post claims, and then strand the foreign ones with no PR that
    # can close them. Boards holding several repos are ordinary here (it is what #523 is about),
    # so every signal below is computed per repo, never across the board as a whole.
    $byRepo = @{}
    foreach ($item in $items) {
        $repo = Get-ItemRepoName $item
        if (-not $byRepo.ContainsKey($repo)) { $byRepo[$repo] = @() }
        $byRepo[$repo] += $item
    }

    foreach ($repo in @($byRepo.Keys | Sort-Object)) {
        $repoItems = @($byRepo[$repo])
        if ($repoItems.Count -lt $MinGroup) { continue }

        # Per REPO, not per board. Issue numbers are unique inside a repository and nowhere else,
        # so a board-wide "already grouped" set keyed on the bare number lets owner/alpha#10 lock
        # out owner/beta#10 - silently, and only on the multi-repo boards this partitioning was
        # added to serve. Scoping the set to the repo makes the collision impossible rather than
        # unlikely.
        $claimed = @{}

        # --- file evidence ---------------------------------------------------
        # Only for the repo this checkout actually is: the token list came from ITS git ls-files.
        # When the current repo is unknown (outside a clone), the signal is skipped rather than
        # applied to a repo whose files were never read.
        $byFile = @{}
        if ($CurrentRepo -and $repo -eq $CurrentRepo) {
            $tokens = Get-RepoFileTokens -Paths $RepoFiles
            foreach ($item in $repoItems) {
                $text = "{0}`n{1}" -f $item.content.title, $item.content.body
                foreach ($token in @($tokens.Keys)) {
                    if (Test-NamesToken -Text $text -Token $token) {
                        $file = $tokens[$token]
                        if (-not $byFile.ContainsKey($file)) { $byFile[$file] = @() }
                        if ($byFile[$file] -notcontains $item.content.number) { $byFile[$file] += $item.content.number }
                    }
                }
            }
        }

        foreach ($file in @($byFile.Keys | Sort-Object)) {
            $nums = @($byFile[$file] | Where-Object { -not $claimed.ContainsKey($_) } | Sort-Object)
            if ($nums.Count -lt $MinGroup) { continue }
            # Claim ALL of them, capped or not: an issue held out of this group for size must not
            # reappear under a weaker signal further down, which would read as a second, unrelated
            # reason to batch it.
            foreach ($n in $nums) { $claimed[$n] = $true }
            $take    = @($nums | Select-Object -First $MaxGroup)
            $dropped = @($nums | Select-Object -Skip  $MaxGroup)
            $suggestions += [pscustomobject]@{
                reason   = 'file'
                evidence = $file
                repo     = $repo
                issues   = $take
                dropped  = $dropped
            }
        }

        # --- area evidence ---------------------------------------------------
        $byArea = @{}
        foreach ($item in $repoItems) {
            $area = $item.area
            if ([string]::IsNullOrWhiteSpace($area)) { continue }
            if ($claimed.ContainsKey($item.content.number)) { continue }
            if (-not $byArea.ContainsKey($area)) { $byArea[$area] = @() }
            $byArea[$area] += $item.content.number
        }

        foreach ($area in @($byArea.Keys | Sort-Object)) {
            $nums = @($byArea[$area] | Sort-Object)
            if ($nums.Count -lt $MinGroup) { continue }
            foreach ($n in $nums) { $claimed[$n] = $true }
            $take    = @($nums | Select-Object -First $MaxGroup)
            $dropped = @($nums | Select-Object -Skip  $MaxGroup)
            $suggestions += [pscustomobject]@{
                reason   = 'area'
                evidence = $area
                repo     = $repo
                issues   = $take
                dropped  = $dropped
            }
        }
    }

    # Biggest saving first - the group that removes the most PR cycles is the one worth
    # reading. Ties break on the evidence name so the output is stable between runs.
    @($suggestions | Sort-Object -Property @{Expression={ @($_.issues).Count }; Descending=$true},
                                           @{Expression={ $_.evidence }; Descending=$false})
}

# Which group the "next step" line should actually offer.
#
# Not simply the biggest one. Suggestions are ordered by saving, and on a board holding several
# repos the biggest can belong to a repo this checkout is not: `-StartGroup` would then create
# the branch here and try to open a PR that cannot close those issues. So the offer is the
# biggest group OF THE CURRENT REPO, and when none of the groups belong here the caller says
# where they do belong instead of naming a batch that cannot be started from this folder.
#
# Returns $null when there is nothing startable here - a real answer, not an empty group.
function Select-StartableGroup {
    [CmdletBinding()]
    param([object[]]$Suggestions, [string]$CurrentRepo)

    $all = @($Suggestions)
    if ($all.Count -eq 0) { return $null }
    # Outside a clone there is no "here" to compare against; the ordering is all we have.
    if (-not $CurrentRepo) { return $all[0] }
    $mine = @($all | Where-Object { $_.repo -eq $CurrentRepo })
    if ($mine.Count -eq 0) { return $null }
    $mine[0]
}

# How many PR cycles a suggestion set removes: N issues that would have cost N PRs now cost 1.
function Get-GroupingSavings {
    [CmdletBinding()]
    param([object[]]$Suggestions)

    $total = 0
    foreach ($s in @($Suggestions)) { $total += (@($s.issues).Count - 1) }
    $total
}

# The repo's tracked files, as evidence for the file signal. `git ls-files` and nothing else:
# the point is to match issue text against files that ACTUALLY EXIST here, so a grouping can
# never be built on a filename the tool imagined. Outside a repo, or on any git failure, it
# returns empty - the area signal still works, and no suggestion is invented from nothing.
function Get-RepoTrackedFiles {
    [CmdletBinding()]
    param()

    try {
        $out = git ls-files 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | Where-Object { $_ })
    } catch { return @() }
}

# Prints the grouping offer under the pending list. Says the SAVING in the currency the user
# actually pays (review rounds and merge confirmations, not "PRs"), names the evidence for
# every group, and ends with the exact selection to accept - so saying yes is one answer, not
# a research task.
function Show-GroupingOffer {
    [CmdletBinding()]
    param(
        [object[]] $Suggestions,
        [string]   $Posture = 'auto',
        [string]   $CurrentRepo = '',
        # Twelve groups is a wall, not an offer. Show the biggest savings and COUNT the rest -
        # the user is choosing where to start, not reading an inventory.
        [int]      $MaxShown = 5
    )

    if ($Posture -eq 'never') {
        Write-Host ""
        Write-Host "Este repo pidio un PR por issue: no agrupo nada aunque se solapen." -ForegroundColor DarkGray
        return
    }
    # 'always' does not invent groups out of nothing - there is no honest way to batch issues
    # that share no file and no area, and a group with no reason behind it is exactly what this
    # feature refuses to produce. What it must NOT do is go silent and look identical to 'auto'
    # with nothing to say: the repo asked for grouping, so when none is possible that is the
    # answer it is owed.
    if (@($Suggestions).Count -eq 0) {
        if ($Posture -eq 'always') {
            Write-Host ""
            Write-Host "Este repo pidio juntar los PRs, pero no hay dos pendientes que se solapen:" -ForegroundColor DarkYellow
            Write-Host "ninguno comparte archivo ni area del board, asi que cada uno va en el suyo." -ForegroundColor DarkGray
        }
        return
    }

    $saved = Get-GroupingSavings -Suggestions $Suggestions
    $all   = @($Suggestions)
    $show  = @($all | Select-Object -First $MaxShown)
    $rest  = @($all | Select-Object -Skip  $MaxShown)

    Write-Host ""
    Write-Host "Se pueden juntar en menos PRs:" -ForegroundColor Cyan
    foreach ($s in $show) {
        $nums   = ($s.issues | ForEach-Object { "#$_" }) -join ', '
        $porque = if ($s.reason -eq 'file') { "los $(@($s.issues).Count) tocan el mismo archivo ($($s.evidence))" }
                  else                      { "los $(@($s.issues).Count) estan en la misma area del board ($($s.evidence))" }
        Write-Host ("  {0}  ->  un solo PR" -f $nums) -ForegroundColor Yellow
        Write-Host ("        porque {0}" -f $porque) -ForegroundColor DarkGray
        # On a board holding several repos, WHICH repo the batch lands in is part of the offer:
        # the PR can only be opened where the issues live.
        if ($CurrentRepo -and $s.repo -and $s.repo -ne $CurrentRepo) {
            Write-Host ("        (en {0}, no en este repo - el PR va alli)" -f $s.repo) -ForegroundColor DarkGray
        }
        # Never let a cap pass for a complete answer: say what was held back and why.
        if (@($s.dropped).Count -gt 0) {
            $more = ($s.dropped | ForEach-Object { "#$_" }) -join ', '
            Write-Host ("        (dejo fuera {0} para que el PR siga siendo revisable - van en un segundo lote)" -f $more) -ForegroundColor DarkGray
        }
    }
    if ($rest.Count -gt 0) {
        $restIssues = 0
        foreach ($r in $rest) { $restIssues += @($r.issues).Count }
        Write-Host ("  ... y {0} grupo(s) mas ({1} issues), por si prefieres empezar por otro lado." -f $rest.Count, $restIssues) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host ("Te ahorra {0} ronda(s) de revision y {0} confirmacion(es) de merge." -f $saved) -ForegroundColor Green
    if ($Posture -eq 'always') {
        Write-Host "Este repo ya pidio juntar lo que se solape, asi que es lo que hare salvo que digas otra cosa." -ForegroundColor DarkGray
    } else {
        Write-Host "Separalos solo si alguno tiene riesgo propio o alguien debe poder aprobarlo o rechazarlo aparte." -ForegroundColor DarkGray
    }
}

# The board's Status options that are LEGACY names this tool would migrate
# (e.g. 'Todo' -> 'Backlog'). Names it does not recognize at all are NOT listed:
# they are the caller's own vocabulary, not something to rename. Pure.
function Get-LegacyStatusOptions([string[]]$OptionNames) {
    @($OptionNames | Where-Object { $_ -and -not (Test-CanonicalOptionName 'Status' $_) -and (Get-CanonicalOptionName 'Status' $_) })
}

# The distinct Status VALUES on the board that map to no canonical option - i.e. the
# board speaks a vocabulary this tool cannot read. While any exist, a pending count of
# 0 proves nothing, so the caller must not claim the board is clean. Pure.
function Get-UnknownStatusValues($items) {
    @($items | ForEach-Object { $_.status } |
        Where-Object { $_ -and -not (Get-CanonicalOptionName 'Status' $_) } |
        Select-Object -Unique)
}

# Resolve a CANONICAL Status option to the id the board actually uses for it: the
# canonical name first, then its legacy aliases. Every WRITE of a Status value must go
# through this - resolving a literal name is what made the tool blind to legacy boards
# in the first place (#278), and a write that resolves to $null silently leaves the item
# where it was. $statusNode is the GraphQL field node (.options with .id/.name).
function Resolve-StatusOptionId($statusNode, [string]$canonical) {
    if (-not $statusNode) { return $null }
    foreach ($n in (Get-OptionAliases 'Status' $canonical)) {
        $o = $statusNode.options | Where-Object { $_.name -eq $n } | Select-Object -First 1
        if ($o) { return $o.id }
    }
    return $null
}

# The Status field's option names as configured on the board. Returns @() when the
# board has no Status field or the call fails - the caller degrades to "cannot tell"
# rather than asserting a schema it never read.
function Get-StatusOptionNames([int]$num) {
    try {
        # Through the wrapper + cache (#571): this exact line was the anti-pattern quoted in
        # Invoke-Gh.ps1's header (a 401 read as "the board has no fields"), still live here.
        # Board field schemas change rarely; 5 minutes of staleness is free speed.
        $fields = (Invoke-GhCached -GhArgs @('project','field-list',"$num",'--owner',$Owner,'--format','json','--limit','50') `
                       -What "leer los campos del board #$num" -Json -TtlSec 300).fields
        @(($fields | Where-Object { $_.name -eq 'Status' } | Select-Object -First 1).options | ForEach-Object { $_.name })
    } catch { @() }
}

# Warn (never block) when the board's Status schema is not the canonical one, and point
# at the migration. Called before any pending claim so the user can weigh the count.
function Show-StatusSchemaWarning([string[]]$OptionNames, [int]$num) {
    $legacy = Get-LegacyStatusOptions $OptionNames
    if ($legacy.Count -eq 0) { return }
    $map = @($legacy | ForEach-Object { "$_ -> $(Get-CanonicalOptionName 'Status' $_)" }) -join ', '
    Write-Host "AVISO: el board no usa el estandar canonico de Status ($map)." -ForegroundColor Yellow
    Write-Host "       Los cuento como pendientes igual, pero para estandarizarlo (renombra en sitio, conserva las asignaciones):" -ForegroundColor DarkGray
    Write-Host "       /board field apply en --migrate      (previsualiza con --dry-run)" -ForegroundColor DarkGray
    Write-Host ""
}

# -- Local session registry (multi-session awareness) ---------------------------
# Shared across worktrees of the same repo: the state dir lives next to the MAIN
# clone's .git (git rev-parse --git-common-dir) so every worktree sees the same one.
# Session identity = the PARENT process of this script (the long-lived Claude/host
# process), because the script's own PID dies as soon as it returns.
function Get-AbiosDir { Get-AbiosStateDir }

function Get-SessionRegistryPath {
    $dir = Get-AbiosDir
    if (-not $dir) { return $null }
    return (Join-Path $dir "sessions.json")
}

function Read-SessionRegistry {
    $p = Get-SessionRegistryPath
    if (-not $p -or -not (Test-Path $p)) { return @() }
    try { $entries = @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return @() }
    # Filter out entries whose session process is dead - callers only ever want live
    # sessions. This is a READ-ONLY view: it does NOT rewrite the file. The old version
    # persisted the pruned list on every read, which silently deleted a dead-PID session
    # before -Watch/-AutoClean could tear down its worktree (a dead PID is a completion
    # signal, not garbage) - Codex review, PR #269. The file self-tidies on the next
    # Write-SessionRegistryEntry (it rebuilds from this filtered read) or Remove-SessionRegistryEntry.
    return @($entries | Where-Object { $_.sessionPid -and (Get-Process -Id $_.sessionPid -ErrorAction SilentlyContinue) })
}

function Write-SessionRegistryEntry {
    param(
        [int]$IssueNum, [string]$Branch, [string]$WorkPath, [string]$Repo = "",
        [int]$SessionPid = 0, [string]$Via = "", [string]$Cli = 'claude',
        [string]$FleetSession = ''
    )
    $p = Get-SessionRegistryPath
    if (-not $p) { return }
    # PID identity: an explicit spawned-session PID wins (a parallel launch tracks the
    # actual worktree session, not the launcher); otherwise the PARENT of this script
    # (the long-lived host session, since the script's own PID dies on return).
    $trackPid = $SessionPid
    if ($trackPid -le 0) {
        try { $trackPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch { }
    }
    if (-not $trackPid) { return }
    # Preserve fields already recorded for this issue (e.g. repo set at start time)
    # when a later launch updates only the PID/via. Read RAW: a relaunch after the old
    # PID died must still inherit the prior branch/repo/workPath.
    $prev = @(Read-SessionRegistryRaw | Where-Object { $_.issue -eq $IssueNum }) | Select-Object -First 1
    if (-not $Repo -and $prev) { $Repo = $prev.repo }
    if (-not $Branch -and $prev) { $Branch = $prev.branch }
    if (-not $WorkPath -and $prev) { $WorkPath = $prev.workPath }
    if (-not $Via -and $prev) { $Via = $prev.via }
    # NOTE: fleetSession is deliberately NOT carried forward. It is a per-LAUNCH
    # fingerprint, not stable session identity - a later marker-less update (e.g. an
    # in-place re-start of an issue that was previously fleet-launched) must NOT keep
    # advertising the old marker, or the reaper would target a fingerprint that no
    # longer matches the tracked process. Every fleet launch writes it explicitly.
    # Rebuild from the RAW registry (remove ONLY the issue being written), not the
    # dead-PID-filtered view - otherwise starting/relaunching one issue would silently
    # drop other issues' finished-but-uncleaned sessions before -Watch/-AutoClean can
    # tear down their worktrees (Codex review, PR #269). The file self-tidies via
    # Remove-SessionRegistryEntry (auto-clean), not as a side-effect of unrelated writes.
    $entries = @(Read-SessionRegistryRaw | Where-Object { $_.issue -ne $IssueNum })
    $entries += [PSCustomObject]@{
        issue        = $IssueNum
        repo         = $Repo
        branch       = $Branch
        workPath     = $WorkPath
        sessionPid   = $trackPid
        via          = $Via
        cli          = $Cli
        fleetSession = $FleetSession
        host         = $env:COMPUTERNAME
        # Seconds, not minutes (#568): this stamp is the start of every duration the tool can
        # ever compute about its own runs; minute granularity threw away the precision for free.
        started      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $entries | ConvertTo-Json -Depth 4 -AsArray | Set-Content $p
}

# -- Branch-drift guard ---------------------------------------------------------
# Warn (NEVER block) when the current working copy's HEAD has drifted away from the
# branch this session started work on HERE - e.g. a foreign Stop hook ran
# `git checkout`/`git switch` mid-session and silently left you on another branch
# (the confusing case the tool itself does NOT cause: our hooks are read-only).
# Pure -> unit-testable. Returns a warning string, or $null when there is no matching
# in-place session for this working copy, or no drift.
#
# It matches the registry entry by BOTH the session PID and the exact working path,
# so a worktree started elsewhere never triggers a false alarm in the main clone,
# and the most-recently-started in-place issue is the expected branch.
function Get-BranchDriftWarning {
    param(
        [object[]] $Sessions,      # Read-SessionRegistry output (live entries)
        [int]      $SessionPid,    # this session's tracking PID (parent of the script)
        [string]   $CurrentBranch, # git branch --show-current in the cwd
        [string]   $CurrentPath    # cwd
    )
    # Detached HEAD or not a git repo -> no branch to compare, nothing to warn about.
    if (-not $CurrentBranch) { return $null }
    $trim = { param($p) if ($p) { $p.TrimEnd('\', '/') } else { $p } }
    $here = & $trim $CurrentPath
    $mine = @($Sessions | Where-Object {
        $_.sessionPid -eq $SessionPid -and $_.branch -and ((& $trim $_.workPath) -ieq $here)
    })
    if ($mine.Count -eq 0) { return $null }
    # started is "yyyy-MM-dd HH:mm" (lexically sortable) -> newest in-place start wins.
    $entry = $mine | Sort-Object -Property started -Descending | Select-Object -First 1
    if ($entry.branch -ieq $CurrentBranch) { return $null }
    return ("HEAD esta en '{0}' pero empezaste el issue #{1} en la rama '{2}' aqui. " -f `
                $CurrentBranch, $entry.issue, $entry.branch) +
           "Algo te movio de rama (posible hook Stop ajeno que hace git checkout). " +
           ("Vuelve con: git checkout {0}" -f $entry.branch)
}

# Emit the branch-drift warning (side-effecting wrapper around Get-BranchDriftWarning).
# Never throws: a diagnostic must not break the /board work flow.
function Show-BranchDrift {
    try {
        $curBr = git branch --show-current 2>$null
        $trackPid = 0
        try { $trackPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch { }
        if (-not $trackPid) { return }
        $warn = Get-BranchDriftWarning -Sessions (Read-SessionRegistry) -SessionPid $trackPid `
                                       -CurrentBranch $curBr -CurrentPath (Get-Location).Path
        if ($warn) {
            Write-Host ""
            Write-Host "  WARN $warn" -ForegroundColor Yellow
        }
    } catch { }
}

# ==============================================================================
# Reusable start helpers (shared by -Start mode 3 and -Parallel mode 5)
# ==============================================================================

# Work branch name: issue-<num>-<slug-from-title>. Pure -> unit-testable.
function Get-IssueSlugBranch([int]$num, [string]$title) {
    $slug = ($title.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) {
        $slug = $slug.Substring(0, 40)
        if ($slug.Contains('-')) { $slug = $slug.Substring(0, $slug.LastIndexOf('-')) }  # no cortar palabras
        $slug = $slug.Trim('-')
    }
    return "issue-$num-$slug"
}

# Normalize a -Parallel request into the batch queue: split comma-separated tokens
# (so `pwsh -File ... -Parallel 129,130` -> "129,130" splits into 129 and 130),
# drop non-positive/non-numeric values, and de-duplicate while preserving the
# requested order. Pure -> unit-testable.
function Get-ParallelQueue([string[]]$nums) {
    $queue = @()
    foreach ($tok in $nums) {
        if ($null -eq $tok) { continue }
        foreach ($part in ($tok -split ',')) {
            $part = $part.Trim()
            if ($part -eq '') { continue }
            $n = 0
            if (-not [int]::TryParse($part, [ref]$n)) { continue }
            if ($n -gt 0 -and $queue -notcontains $n) { $queue += $n }
        }
    }
    # No unary-comma wrap: it would turn an empty queue into a 1-element array
    # (an array holding @()). Callers wrap with @() to normalize the single case.
    return $queue
}

# Resolve the board id + Status field + "In Progress" option once, reuse per issue.
function Resolve-BoardStatus([string]$owner, [int]$projectNum) {
    # -Graphql fails closed on a non-zero exit AND on an exit-0 errors[] body, so a read failure
    # throws here (naming the board) instead of a null id mislabelled "board not found" (#303/#314).
    $statusQuery = '
query($owner:String!, $num:Int!) {
  user(login:$owner) {
    projectV2(number:$num) {
      id
      fields(first:30) {
        nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
}'
    $projData = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$statusQuery",'-F',"owner=$owner",'-F',"num=$projectNum") `
                          -What "resolver el board #$projectNum de $owner" -Graphql

    $projectId  = $projData.data.user.projectV2.id
    if (-not $projectId) { throw "Board #$projectNum no encontrado para $owner." }
    $statusNode = $projData.data.user.projectV2.fields.nodes | Where-Object { $_.name -eq "Status" }
    $inProgId   = ($statusNode.options | Where-Object { $_.name -eq "In Progress" }).id
    if (-not $inProgId) { throw "El board #$projectNum no tiene la opcion 'In Progress' en Status." }
    return [PSCustomObject]@{ projectId = $projectId; statusNode = $statusNode; inProgId = $inProgId }
}

# Accumulate all nodes across GraphQL project-item pages. $FetchPage is called with a
# cursor ($null on the first call) and must return @{ nodes; hasNext; endCursor } for
# that page. Pure w.r.t. its injected fetcher -> unit-testable with a fake page source.
# Fixes #246: board lookups used items(first:100) with no pagination, so issues past
# the first 100 board items were invisible (a 148-item board hid the newest issues, and
# -Start/-ToReview/-Parallel/-Fleet all failed on them via Get-BoardItem).
function Get-AllPages {
    param([scriptblock]$FetchPage)
    $all = @(); $cursor = $null
    do {
        $page = & $FetchPage $cursor
        if (-not $page) { break }
        $all += @($page.nodes)
        $cursor = $page.endCursor
        $more   = [bool]$page.hasNext
    } while ($more)
    return $all
}

# Find the board item for an issue number, paginating the WHOLE board (issue #246) with
# one retry for GitHub eventual consistency. $projectId is closed over by the fetcher.
function Get-BoardItem([string]$projectId, [int]$issueNum) {
    foreach ($attempt in 1..2) {
        $nodes = Get-AllPages {
            param($cursor)
            # The cursor rides as a GraphQL VARIABLE (-f cursor=), NOT interpolated into the query
            # as after: "$cursor". Embedded double-quotes in a native gh.exe argument are not escaped
            # by PowerShell, so gh saw the base64 cursor unquoted and its `==` padding parsed as bare
            # tokens -> "Expected NAME, actual EQUALS" on every board >100 items (#329). `$cursor is
            # backtick-escaped so the query carries the literal variable ref, not the value.
            $q = @"
query(`$proj:ID!, `$cursor:String) {
  node(id:`$proj) {
    ... on ProjectV2 {
      items(first:100, after:`$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
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
              number title state url
              assignees(first:5) { nodes { login } }
              repository { nameWithOwner }
            }
          }
        }
      }
    }
  }
}
"@
            # -Graphql + retries: a transient failure retries, a hard failure (or errors[]) THROWS
            # instead of silently truncating pagination -> a target issue falsely "not on board" (#314).
            $ghArgs = @('api','graphql','-f',"query=$q",'-F',"proj=$projectId")
            if ($cursor) { $ghArgs += @('-f',"cursor=$cursor") }
            $resp  = Invoke-Gh -GhArgs $ghArgs -What "leer los items del board" -Graphql -Retries 2
            $items = $resp.data.node.items
            return @{ nodes = $items.nodes; hasNext = $items.pageInfo.hasNextPage; endCursor = $items.pageInfo.endCursor }
        }
        $item = $nodes |
                Where-Object { $_.content.__typename -eq "Issue" -and $_.content.number -eq $issueNum } |
                Select-Object -First 1
        if ($item) { return $item }
        if ($attempt -eq 1) {
            Write-Host "  (issue #$issueNum aun no visible en el board - reintentando en 4s...)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 4
        }
    }
    return $null
}

# Return the list of reasons this issue is blocked (empty array => not blocked).
function Get-IssueBlockers([string]$repo, [int]$issueNum) {
    $blockers = @()
    try {
        $issueLabels = @((gh issue view $issueNum --repo $repo --json labels | ConvertFrom-Json).labels.name)
        if ($issueLabels -contains "blocked") { $blockers += "label 'blocked' presente" }
    } catch { }
    # Native blocked-by dependencies (best-effort: API may not exist for the account). Through
    # the wrapper (#571): the raw 2>$null read made a 401 indistinguishable from "no blockers" -
    # the try/catch keeps the degrade, but now only a REAL absence degrades silently.
    try {
        $deps = Invoke-Gh -GhArgs @('api',"repos/$repo/issues/$issueNum/dependencies/blocked_by") `
                          -What "leer los bloqueadores de #$issueNum" -Json
        foreach ($d in @($deps | Where-Object { $_.state -eq "open" })) {
            $blockers += "bloqueado por #$($d.number) '$($d.title)' (abierto)"
        }
    } catch { }
    return $blockers
}

# Last [abios-claim] fingerprint comment on an issue (or empty). Wrapped so the
# multi-session lock path can be unit-tested without a live gh call. Best-effort by contract
# (an unreadable claim list must not block a start), so the wrapper's throw degrades to ''.
function Get-LastClaim([string]$repo, [int]$issueNum) {
    try {
        return (Invoke-Gh -GhArgs @('api',"repos/$repo/issues/$issueNum/comments",'--jq','[.[] | select(.body | startswith("[abios-claim]"))] | last | .body') `
                          -What "leer los claims de #$issueNum")
    } catch { return '' }
}

# Build the durable [abios-claim] fingerprint comment body. Pure -> unit-testable,
# and the single source of the fingerprint format: -Start posts it (claim/TAKEOVER)
# and the -Lock/-Unlock subcommand posts it (LOCK/UNLOCK) so they never drift.
function Format-ClaimFingerprint {
    param([string]$Note, [string]$Computer, [int]$ProcessId, [string]$Date, [string]$Branch = '')
    $tail = if ($Branch) { " - rama $Branch" } else { "" }
    return "[abios-claim] $Note por sesion Claude en $Computer (PID $ProcessId) - $Date$tail"
}

# Decide whether an issue already has landed/active work that -Start should refuse,
# EVEN with no [abios-claim] comment (issue #236: a session can merge to main without
# posting a formal claim, and the assignee is always the shared bot owner). Pure ->
# unit-testable. $Prs: objects with .number/.state (OPEN|MERGED|CLOSED); $Commits:
# objects with .sha (already filtered to those citing this issue on the default
# branch). Returns a human reason or '' (no refusal). Precedence: a MERGED PR or an
# integrated commit means the work is DONE; an OPEN PR means a session is mid-flight.
# CLOSED-unmerged PRs are ignored so an abandoned attempt never blocks a fresh start.
function Get-PriorWorkRefusal {
    param([object[]]$Prs = @(), [object[]]$Commits = @())
    $merged = @($Prs | Where-Object { $_.state -eq 'MERGED' })
    if ($merged.Count -gt 0) {
        return "ya tiene un PR MERGED (#$($merged[0].number)) - el trabajo ya esta en la rama por defecto"
    }
    if (@($Commits).Count -gt 0) {
        $sha   = "$($Commits[0].sha)"
        $short = if ($sha.Length -ge 7) { $sha.Substring(0, 7) } else { $sha }
        return "un commit ($short) ya cita este issue en la rama por defecto - trabajo integrado"
    }
    $open = @($Prs | Where-Object { $_.state -eq 'OPEN' })
    if ($open.Count -gt 0) {
        return "tiene un PR abierto (#$($open[0].number)) - otra sesion probablemente lo trabaja"
    }
    return ''
}

# Gather landed/active work signals for an issue: PRs that would close it, and
# default-branch commits whose subject cites (#n). Best-effort (never throws) so a
# transient gh failure degrades to "no prior work" instead of blocking a start.
# Wrapped so Invoke-IssueStart's PR/commit-aware refusal is unit-testable via a mock.
function Get-IssueLinkedWork {
    param([string]$Repo, [int]$IssueNum)
    $prs = @(); $commits = @()
    $rp = $Repo -split '/'
    try {
        $data = Invoke-Gh -GhArgs @('api','graphql','-f','query=
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    issue(number:$n){
      closedByPullRequestsReferences(first:10, includeClosedPrs:true){
        nodes { number state }
      }
    }
  }
}','-F',"o=$($rp[0])",'-F',"r=$($rp[1])",'-F',"n=$IssueNum") -What "leer los PRs de #$IssueNum" -Graphql
        $prs = @($data.data.repository.issue.closedByPullRequestsReferences.nodes)
    } catch { }
    # GitHub commit search indexes the DEFAULT branch. Filter to the exact (#n) token
    # so #12 never matches #123 (substring search would).
    try {
        $hits = Invoke-Gh -GhArgs @('search','commits',"#$IssueNum",'--repo',$Repo,'--json','sha,commit','--limit','20') `
                          -What "buscar commits de #$IssueNum" -Json
        $rx = "\(#$IssueNum\)"
        $commits = @($hits | Where-Object { $_.commit.message -match $rx } |
                     ForEach-Object { [pscustomobject]@{ sha = $_.sha } })
    } catch { }
    return [pscustomobject]@{ prs = $prs; commits = $commits }
}

# Where an issue's worktree lives: <parent>/<repo>--worktrees/issue-<n>. Pure ->
# unit-testable. All worktrees are GROUPED under one `<repo>--worktrees` folder
# (instead of scattered siblings `<repo>--issue-<n>`), which keeps the repo's parent
# directory clean, makes `git worktree list` read grouped, and lets you clean the
# whole fleet by removing a single folder.
function Get-IssueWorktreePath([string]$repo, [int]$issueNum, [string]$parentDir) {
    $repoName = ($repo -split '/')[1]
    return (Join-Path (Join-Path $parentDir "$repoName--worktrees") "issue-$issueNum")
}

# The ref a NEW issue branch must start from: the remote's default branch, freshly
# fetched. Cutting the branch from the current HEAD instead is what let another
# branch's unmerged commits ride into an issue's PR - a 1-line fix that opened as 56
# files, +2332/-253, and passed the gate (#294). Basing on the current HEAD is still
# legitimate for dependent work, so it stays available, but as an OPT-IN (-BaseCurrent).
#
# Best-effort by design: every step degrades instead of throwing, because a repo with
# no reachable origin still has to be able to start an issue - it just cannot promise
# a clean base, and says so at the call site.
function Resolve-IssueBaseRef([string]$repo = "", [switch]$NoFetch) {
    if (-not $NoFetch) { git fetch origin --quiet 2>$null | Out-Null }

    # 1. origin/HEAD - what this clone recorded as the remote's default branch.
    $head = git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        git rev-parse --verify --quiet $head 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $head }
    }

    # 2. Ask GitHub. origin/HEAD is written at clone time: it is absent in fetch-built
    #    clones and stale if the remote's default moved since.
    if ($repo) {
        $name = gh repo view $repo --json defaultBranchRef -q .defaultBranchRef.name 2>$null
        if ($LASTEXITCODE -eq 0 -and $name) {
            git rev-parse --verify --quiet "origin/$name" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return "origin/$name" }
        }
    }

    # 3. Convention, verified - never return a ref that does not resolve.
    foreach ($candidate in @('origin/main', 'origin/master')) {
        git rev-parse --verify --quiet $candidate 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return ""
}

# Check out the issue branch in the CURRENT working copy (the non-worktree path: the
# tree is clean and not parked on another issue-*). Same base discipline as the worktree
# path (#294) - a clean working copy parked on a feature branch is not dirty and does not
# match issue-*, so it lands HERE, and a bare `checkout -b` off that HEAD drags the
# feature branch's commits into this issue's PR exactly like the worktree path did.
# Extracted so the base choice is unit-testable against a real repo without mocking gh.
# Returns the ref the branch was based on ('' = current HEAD, 'existing' = no new branch).
function New-IssueBranchInPlace([string]$branchName, [string]$baseRef = "") {
    git rev-parse --verify --quiet $branchName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        git checkout $branchName 2>&1 | Out-Null
        Write-Host "  OK  Rama $branchName ya existia - checkout hecho" -ForegroundColor Green
        return 'existing'
    }
    if ($baseRef) {
        git checkout -b $branchName $baseRef 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  OK  Rama $branchName creada y activa (desde $baseRef)" -ForegroundColor Green
            return $baseRef
        }
        # An unresolvable base must not silently become "branch off HEAD" - that is the
        # #294 failure mode wearing a different hat. Say so, then fall back loudly.
        Write-Host "  WARN no pude basar la rama en '$baseRef' - uso el HEAD actual." -ForegroundColor DarkYellow
        Write-Host "       Revisa que el PR no arrastre commits ajenos antes de mergear." -ForegroundColor DarkYellow
    }
    git checkout -b $branchName 2>&1 | Out-Null
    Write-Host "  OK  Rama $branchName creada y activa (desde el HEAD actual)" -ForegroundColor Green
    return ''
}

# Create an isolated worktree <parent>/<repo>--worktrees/issue-<n> for a branch.
# Returns the path or $null. $baseRef (e.g. origin/main) is used only when creating a
# NEW branch; "" falls back to the current HEAD (see Resolve-IssueBaseRef for why that
# is the fallback and not the default).
function New-IssueWorktree([string]$repo, [int]$issueNum, [string]$branchName, [string]$baseRef = "") {
    $wtPath   = Get-IssueWorktreePath $repo $issueNum (Split-Path (Get-Location) -Parent)
    # Reuse: is the branch already checked out in some worktree?
    $wtList = git worktree list --porcelain 2>$null | Out-String
    if ($wtList -match "(?m)^worktree (.+)\r?\n(?:.*\r?\n)?branch refs/heads/$([regex]::Escape($branchName))") {
        $existingPath = $Matches[1]
        Write-Host "  OK  Worktree ya existia para la rama: $existingPath" -ForegroundColor Green
        Write-Host "       TRABAJA EL ISSUE ALLI: cd `"$existingPath`"" -ForegroundColor Cyan
        return $existingPath
    }
    if (Test-Path $wtPath) {
        Write-Host "  WARN la carpeta $wtPath existe pero no es worktree de $branchName - resuelvelo manualmente." -ForegroundColor DarkYellow
        return $null
    }
    # Ensure the grouping folder (<repo>--worktrees) exists before adding into it.
    # `git worktree add` creates leading dirs, but this keeps the intent explicit.
    $wtParent = Split-Path $wtPath -Parent
    if (-not (Test-Path $wtParent)) { New-Item -ItemType Directory -Path $wtParent -Force | Out-Null }
    git rev-parse --verify --quiet $branchName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0)     { git worktree add $wtPath $branchName 2>&1 | Out-Null }
    elseif ($baseRef)            { git worktree add $wtPath -b $branchName $baseRef 2>&1 | Out-Null }
    else                         { git worktree add $wtPath -b $branchName 2>&1 | Out-Null }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK  Worktree creado: $wtPath (rama $branchName)" -ForegroundColor Green
        Write-Host "       TRABAJA EL ISSUE ALLI: cd `"$wtPath`"" -ForegroundColor Cyan
        Write-Host "       Al mergear el PR, limpia con: git worktree remove `"$wtPath`"" -ForegroundColor DarkGray
        return $wtPath
    }
    Write-Host "  FAIL no se pudo crear el worktree para #$issueNum - crea la rama manualmente: git checkout -b $branchName" -ForegroundColor Red
    return $null
}

# Give the issue a place to be worked: pick the base, then either an isolated worktree
# or the branch in place. Returns the work path ('' when the cwd is not a clone of the
# issue's repo, so no branch was made).
#
# This exists as a function, rather than inline in Invoke-IssueStart, because it is the
# WIRING that #294 got wrong - New-IssueWorktree already honoured a base ref; nobody
# passed it one. A test that hands the base in by itself would pass against the buggy
# code, so the base choice has to live somewhere a test can reach it with real git.
function New-IssueWorkspace {
    param(
        [string]$repo,
        [int]   $issueNum,
        [string]$branchName,
        [switch]$PreferWorktree,
        [string]$Base = "",
        [switch]$BaseCurrent
    )
    $originUrl = git remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or $originUrl -notmatch [regex]::Escape($repo)) {
        Write-Host "  WARN el directorio actual no es un clon de $repo - rama NO creada." -ForegroundColor DarkYellow
        Write-Host "       Crea la rama en ese repo con: git checkout -b $branchName" -ForegroundColor DarkYellow
        return ""
    }

    # -- The base (#294). Explicit wins; otherwise resolve the remote default. -----
    $baseRef = ""
    if ($BaseCurrent) {
        Write-Host "  -BaseCurrent: la rama nace del HEAD actual (trabajo dependiente)." -ForegroundColor DarkGray
    } elseif ($Base) {
        $baseRef = $Base
    } else {
        $baseRef = Resolve-IssueBaseRef -repo $repo
        if (-not $baseRef) {
            Write-Host "  WARN no pude resolver la rama por defecto del remoto - la rama nace del HEAD actual." -ForegroundColor DarkYellow
            Write-Host "       Revisa que el PR no arrastre commits ajenos antes de mergear." -ForegroundColor DarkYellow
        }
    }

    $dirty     = @(git status --porcelain 2>$null)
    $curBranch = git branch --show-current 2>$null
    # Detect another LIVE session already using this working copy (#225): a clean tree on
    # master is no defence — a foreign session can switch branches mid-work and corrupt the
    # next commit. Read-SessionRegistry returns only live (process exists) entries.
    $myPid = 0
    try { $myPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch { }
    $cwd   = (Get-Location).Path.TrimEnd('\', '/')
    $conflictEntry = $null
    if ($myPid) {
        $conflictEntry = @(Read-SessionRegistry) | Where-Object {
            $_.sessionPid -ne $myPid -and
            ($_.workPath -and $_.workPath.TrimEnd('\', '/') -ieq $cwd)
        } | Select-Object -First 1
    }
    $liveConflict = [bool]$conflictEntry
    # Batch (-PreferWorktree) always isolates. Single start keeps the classic
    # dirty-tree / other-issue-branch guard: never switch a busy working copy.
    $needWorktree = $PreferWorktree -or $liveConflict -or `
                    ($dirty.Count -gt 0 -and $curBranch -ne $branchName) -or `
                    ($curBranch -and $curBranch -match '^issue-\d+' -and $curBranch -ne $branchName)
    if ($needWorktree) {
        if (-not $PreferWorktree) {
            $reason = if ($liveConflict) {
                "otra sesion viva (issue #$($conflictEntry.issue), PID $($conflictEntry.sessionPid)) usa este mismo directorio de trabajo"
            } else { "working tree ocupado (rama actual: $curBranch)" }
            Write-Host "  OCUPADO: $reason - uso un worktree aislado:" -ForegroundColor Yellow
        }
        return (New-IssueWorktree $repo $issueNum $branchName $baseRef)
    }
    New-IssueBranchInPlace $branchName $baseRef | Out-Null
    return (Get-Location).Path
}

# Start ONE issue: find item, run safety checks, and (unless -DryRunStart) move it
# to In Progress + assign + claim + optionally branch/worktree. Writes progress and
# returns a structured result so callers (single or batch) can decide what to print
# and how to exit. -PreferWorktree forces an isolated worktree (batch); otherwise the
# in-place-vs-worktree decision matches the classic single-start behaviour.
function Invoke-IssueStart {
    param(
        [int]    $IssueNum,
        [object] $Ctx,
        [string] $Owner,
        [switch] $MakeBranch,
        [switch] $PreferWorktree,
        [string] $Base = "",
        [switch] $BaseCurrent,
        [switch] $DryRunStart,
        [switch] $IgnoreBlocked,
        [switch] $TakeOver
    )
    $result = [PSCustomObject]@{
        issue = $IssueNum; title = ""; repo = ""; branch = ""; workPath = ""
        started = $false; dryRun = [bool]$DryRunStart; skipped = ""
    }

    $item = Get-BoardItem $Ctx.projectId $IssueNum
    if (-not $item) {
        $result.skipped = "no esta en el board (agregalo con /board add)"
        Write-Host "  SKIP #${IssueNum}: $($result.skipped)" -ForegroundColor DarkYellow
        return $result
    }

    $result.title = $item.content.title
    $repo         = $item.content.repository.nameWithOwner
    $result.repo  = $repo
    $currentStatus = ($item.fieldValues.nodes | Where-Object { $_.field.name -eq "Status" }).name
    if (-not $currentStatus) { $currentStatus = "(vacio)" }

    if ($item.content.state -eq "CLOSED") {
        $result.skipped = "CERRADO (reabre con gh issue reopen $IssueNum --repo $repo)"
        Write-Host "  SKIP #${IssueNum}: $($result.skipped)" -ForegroundColor Red
        return $result
    }

    if (-not $IgnoreBlocked) {
        $blockers = @(Get-IssueBlockers $repo $IssueNum)
        if ($blockers.Count -gt 0) {
            $result.skipped = "BLOQUEADO: " + ($blockers -join "; ")
            Write-Host "  SKIP #${IssueNum}: bloqueado (usa -IgnoreBlocked si es falso positivo):" -ForegroundColor Red
            $blockers | ForEach-Object { Write-Host "         - $_" -ForegroundColor Red }
            return $result
        }
    }

    $assignees = @($item.content.assignees.nodes.login)
    if (-not $TakeOver -and $currentStatus -eq "In Progress" -and $assignees.Count -gt 0) {
        $result.skipped = "OCUPADO (In Progress, asignado a $($assignees -join ', '))"
        Write-Host "  SKIP #${IssueNum}: $($result.skipped) - otra sesion probablemente lo trabaja." -ForegroundColor Red
        $lastClaim = Get-LastClaim $repo $IssueNum
        if ($lastClaim -and $lastClaim -ne "null") { Write-Host "         Ultimo claim: $lastClaim" -ForegroundColor Yellow }
        Write-Host "         Re-ejecuta con -TakeOver si la sesion esta muerta o quieres retomarlo." -ForegroundColor Yellow
        return $result
    }

    # PR/commit-aware refusal (issue #236): even with NO [abios-claim] comment and the
    # shared bot owner, a merged/open PR or an integrated commit citing (#n) means the
    # issue is already worked - refuse so a second session cannot clobber landed work.
    if (-not $TakeOver) {
        $linked = Get-IssueLinkedWork $repo $IssueNum
        $priorReason = Get-PriorWorkRefusal -Prs $linked.prs -Commits $linked.commits
        if ($priorReason) {
            $result.skipped = "YA TRABAJADO: $priorReason"
            Write-Host "  SKIP #${IssueNum}: $($result.skipped)" -ForegroundColor Red
            Write-Host "         Re-ejecuta con -TakeOver si de verdad quieres re-trabajarlo." -ForegroundColor Yellow
            return $result
        }
    }

    $branchName    = Get-IssueSlugBranch $IssueNum $item.content.title
    $result.branch = $branchName

    Write-Host ("  #{0} {1}" -f $IssueNum, $item.content.title) -ForegroundColor Yellow
    Write-Host ("       Repo: {0} | Status actual: {1} -> In Progress | Assignee -> {2}" -f $repo, $currentStatus, $Owner) -ForegroundColor DarkGray
    if ($MakeBranch) { Write-Host "       Rama de trabajo: $branchName" -ForegroundColor DarkGray }

    if ($DryRunStart) {
        Write-Host "  #${IssueNum}: DRY-RUN - nada ejecutado." -ForegroundColor Gray
        return $result
    }

    # -- Execute: Status -> In Progress -----------------------------------------
    # -Graphql throws on a non-zero exit OR an exit-0 errors[] body, so we never print "OK" for a
    # move that never happened - the whole start aborts loudly instead (the issue must really be
    # In Progress before we claim/branch it, or the multi-session guard is built on a lie) (#314).
    $startStatusMutation = '
mutation($proj:ID!,$item:ID!,$field:ID!,$opt:String!) {
  updateProjectV2ItemFieldValue(input:{
    projectId:$proj, itemId:$item, fieldId:$field,
    value:{singleSelectOptionId:$opt}
  }) { projectV2Item { id } }
}'
    $null = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$startStatusMutation",'-f',"proj=$($Ctx.projectId)",'-f',"item=$($item.id)",'-f',"field=$($Ctx.statusNode.id)",'-f',"opt=$($Ctx.inProgId)") `
                      -What "mover #$IssueNum a In Progress" -Graphql
    Write-Host "  OK  Status -> In Progress" -ForegroundColor Green

    # -- Execute: assign owner --------------------------------------------------
    # Routed through Invoke-Gh so the catch actually fires: a bare native non-zero never threw, so
    # the old try/catch printed "OK Assignee" for an assignment that silently failed (#314). The
    # warn-and-continue policy is preserved deliberately.
    try {
        $null = Invoke-Gh -GhArgs @('api',"repos/$repo/issues/$IssueNum/assignees",'-X','POST','-F',"assignees[]=$Owner") `
                          -What "asignar #$IssueNum a $Owner"
        Write-Host "  OK  Assignee -> $Owner" -ForegroundColor Green
    } catch {
        Write-Host "  WARN no se pudo asignar: $_" -ForegroundColor DarkYellow
    }

    # -- Execute: claim fingerprint (multi-session diagnostics) -----------------
    $claimNote = if ($TakeOver) { "TAKEOVER" } else { "claim" }
    $fingerprint = Format-ClaimFingerprint -Note $claimNote -Computer $env:COMPUTERNAME -ProcessId $PID -Date (Get-Date -Format 'yyyy-MM-dd HH:mm') -Branch $branchName
    try {
        $null = Invoke-Gh -GhArgs @('issue','comment',"$IssueNum",'--repo',$repo,'--body',$fingerprint) `
                          -What "registrar el claim en #$IssueNum"
        Write-Host "  OK  Claim registrado ($claimNote)" -ForegroundColor Green
    } catch {
        Write-Host "  WARN no se pudo registrar el claim: $_" -ForegroundColor DarkYellow
    }

    # -- Execute: work branch (only if cwd is a clone of the issue's repo) -------
    if ($MakeBranch) {
        $result.workPath = New-IssueWorkspace -repo $repo -issueNum $IssueNum -branchName $branchName `
                                              -PreferWorktree:$PreferWorktree -Base $Base -BaseCurrent:$BaseCurrent
        if ($result.workPath) {
            Write-SessionRegistryEntry -IssueNum $IssueNum -Branch $branchName -WorkPath $result.workPath -Repo $repo
            Write-Host "  OK  Sesion registrada en .agentic-board/sessions.json" -ForegroundColor Green
        }
    }

    $result.started = $true
    return $result
}

# Print the full issue context so an in-session agent can start working (mode 3).
function Write-IssueContext([int]$issueNum, [string]$repo) {
    $issue = gh issue view $issueNum --repo $repo --json title,body,labels,milestone,url,state | ConvertFrom-Json
    Write-Host "----- CONTEXTO DEL ISSUE -----" -ForegroundColor Cyan
    Write-Host ("Titulo : {0}" -f $issue.title)
    Write-Host ("URL    : {0}" -f $issue.url)
    $labelNames = @($issue.labels | ForEach-Object { $_.name })
    if ($labelNames.Count -gt 0) { Write-Host ("Labels : {0}" -f ($labelNames -join ", ")) }
    if ($issue.milestone)        { Write-Host ("Hito   : {0}" -f $issue.milestone.title) }
    Write-Host ""
    if ($issue.body) { Write-Host $issue.body } else { Write-Host "(sin descripcion)" -ForegroundColor DarkGray }
    Write-Host ""
    try {
        $repoParts = $repo -split "/"
        $subData = gh api graphql -f query='
query($o:String!, $r:String!, $n:Int!) {
  repository(owner:$o, name:$r) {
    issue(number:$n) {
      subIssues(first:30) { nodes { number title state } }
    }
  }
}' -F "o=$($repoParts[0])" -F "r=$($repoParts[1])" -F "n=$issueNum" 2>$null | ConvertFrom-Json
        $subs = @($subData.data.repository.issue.subIssues.nodes)
        if ($subs.Count -gt 0) {
            Write-Host "Sub-issues:" -ForegroundColor Cyan
            foreach ($s in $subs) { Write-Host ("  #{0} [{1}] {2}" -f $s.number, $s.state, $s.title) }
            Write-Host ""
        }
    } catch { }
    Write-Host "------------------------------" -ForegroundColor Cyan
}

# ==============================================================================
# Parallel session launcher (mode 5 -Launch): one visible Claude session per
# worktree, each briefed to work its own issue end-to-end.
# ==============================================================================

# Compute the effective brake for a launched session (#598).
# All launched sessions stop at a reviewed PR by default — a session that merges its
# own PR has no human review and the board has no safety check on the result (proven on
# 2026-08-03: two sessions merged unreviewed, one shipped a DoD item it had not built).
# -AllowMerge is the explicit opt-in for autonomous merging; -StopAtPR:$false from an
# expert contract that allows merging is also honoured. -AllowMerge beats everything.
# Pure (no side effects) -> unit-testable. Called from the -Launch and -Fleet paths.
function Resolve-LaunchBrake {
    param(
        [bool]$AllowMerge,
        # Was -StopAtPR explicitly bound by the caller? ($PSBoundParameters.ContainsKey('StopAtPR'))
        [bool]$StopAtPRBound,
        [bool]$StopAtPR
    )
    if ($AllowMerge) { return $false }
    if ($StopAtPRBound) { return $StopAtPR }
    return $true    # default: brake for every fleet/launch session (#598)
}

# The one-line first message a spawned Claude session receives. Pure -> testable.
# -Cli is threaded (default 'claude') so Phase-2 adapters can specialize the leading
# autonomy sentence per CLI without another signature change; Phase 1 keeps the
# body text identical for every repl CLI.
#
# -StopAtPR is the irreversible brake (#440). The auto-expert's contract can mark `merge` as
# irreversible, but that brake used to live ONLY in expert-brief-<n>.md - a file this launcher
# never read - while THIS briefing ordered the merge outright and made it the completion
# condition. A session that merged to main was obeying its brief, not defying it. With the
# brake on, the merge step is never emitted and the finish line moves to a reviewed PR.
# -BriefFile is the other half: it hands the session the expert brief it was never given.
function Get-SessionBriefing {
    param(
        [int]$issueNum,
        [string]$repo,
        [string]$branch,
        [string]$workPath,
        [string]$Cli = 'claude',
        [switch]$StopAtPR,
        [string]$BriefFile = ''
    )
    # Steps after the review gate are renumbered so the brake never leaves a hole at (5).
    $mergeStep = if ($StopAtPR) { "" } else {
        "(5) merge it (ruleset-safe): pwsh plugins/agentic-board/scripts/Board-Merge.ps1 -PR <pr> ; "
    }
    $recordNum = if ($StopAtPR) { "(5)" } else { "(6)" }
    $closing = if ($StopAtPR) {
        "Then STOP: leave the PR open and ready for the human to merge. Your contract marks the " +
        "merge as irreversible - do NOT merge, deploy, publish or delete anything, and do not " +
        "treat the merge as your finish line. You are done when the PR is open, the review gate " +
        "is green and your findings are recorded."
    } else {
        "When the PR is merged and your findings recorded, you are done."
    }
    $briefLine = if ($BriefFile) {
        "Your full brief for this run is at $BriefFile - read it FIRST and follow it; where it " +
        "conflicts with the generic steps below, it overrides them. "
    } else { "" }
    return ($briefLine +
            "You are running AUTONOMOUSLY - permissions are pre-approved, so work this " +
            "task end-to-end WITHOUT stopping to ask for confirmation. " +
            "Pick up GitHub issue #$issueNum in $repo. It is already In Progress and claimed, " +
            "on branch $branch in this worktree ($workPath). " +
            "FIRST load fleet coordination context so you collaborate with sibling sessions: " +
            "read prior findings with 'pwsh plugins/agentic-board/scripts/Fleet-Findings.ps1 -List' ; " +
            "inherit any upstream hand-off with 'pwsh plugins/agentic-board/scripts/Fleet-Handoff.ps1 -Context -Issue $issueNum' ; " +
            "and once you know which files you will edit, claim them with " +
            "'pwsh plugins/agentic-board/scripts/Fleet-Ownership.ps1 -Claim -Issue $issueNum -Branch $branch -Paths <files>' " +
            "(if it warns of overlap with another live session, steer clear of those files). Then: " +
            "(1) read it with: gh issue view $issueNum --repo $repo ; " +
            "(2) implement it fully in this worktree and commit your changes ; " +
            "(3) open the PR with: pwsh plugins/agentic-board/scripts/New-BoardPR.ps1 -Issue $issueNum " +
            "and note the PR number it prints ; " +
            "(4) pass the review gate: pwsh plugins/agentic-board/scripts/Board-ReviewGate.ps1 -PR <pr> ; " +
            "address any feedback and re-run until it is green ; " +
            $mergeStep +
            "$recordNum record what you learned for other sessions with " +
            "'pwsh plugins/agentic-board/scripts/Fleet-Findings.ps1 -Add -Issue $issueNum -Status done -Files <files touched> -Decisions <key decisions> -Gotchas <pitfalls>' " +
            "and free your files with 'pwsh plugins/agentic-board/scripts/Fleet-Ownership.ps1 -Release -Issue $issueNum' . " +
            "Work ONLY this issue - never touch other worktrees or issues. " + $closing)
}

# -- Fleet session marker (reaper fingerprint) ---------------------------------
# Every fleet-spawned session is stamped at launch with ABIOS_FLEET_SESSION=<issue>-<runId>
# in its generated launch-<n>.ps1, so the child (claude/antigravity/...) and its CLI grandchild
# carry it in their environment. The task reaper (Find-FleetOrphans) keys on this marker -
# a far stronger discriminator than a bare binary name, since the operator runs many
# unrelated claude/node processes.

# A short per-run token that ties together all sessions launched in one dispatch.
function New-FleetRunId { [guid]::NewGuid().ToString('N').Substring(0, 8) }

# Compose the marker for one session. PURE -> unit-testable. The runId is reduced to a bare
# alphanumeric token so the marker is safe to embed verbatim in a single-quoted env
# assignment AND to match later with a WQL/`-like` fingerprint (no quotes, spaces or slashes).
function New-FleetSessionMarker([int]$IssueNum, [string]$RunId) {
    $safe = ($RunId -replace '[^A-Za-z0-9]', '')
    return ("{0}-{1}" -f $IssueNum, $safe)
}

# Build the exact launch command for a worktree session. Returns an object
# { launcher, args, briefingFile, launchScriptFile, launchScript } WITHOUT spawning -
# pure enough to unit-test and to preview under -DryRun. Windows Terminal tab when
# 'wt' exists (grouped in a named window), else a standalone pwsh window.
#
# CRITICAL - why the setup runs from a .ps1 FILE, not an inline `-Command`:
# Windows Terminal's `wt` command line uses ';' as its OWN sub-command separator
# (new-tab ; split-pane ; ...). A `pwsh -Command "a; b; c"` passed to `wt` therefore
# had its ';' eaten by wt, which split ONE intended tab into FOUR (one per segment) -
# 2 issues -> 8 stray tabs, and the real `claude -p` landed in a bare tab with no
# auth setup, so no session actually worked its issue. Writing the setup+run to
# launch-<issue>.ps1 and launching `pwsh -NoExit -File <script>` puts ZERO ';' on
# wt's command line, so wt opens exactly one tab. The briefing is likewise passed by
# file so no long/quoted text ever hits the command line.
function Build-WorktreeLaunch([int]$issueNum, [string]$workPath, [string]$briefingFile, [string]$windowName = "abios-parallel", [string]$claudeAuthVar = "ANTHROPIC_API_KEY", [string]$Cli = 'claude', [string]$fleetSession = '', [string]$logPath = '') {
    $tabTitle  = "issue-$issueNum"
    # Defense-in-depth: this name is interpolated into the spawned launch script,
    # so it MUST be a bare env-var identifier - never let ';'/quotes/spaces through.
    if ($claudeAuthVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "ClaudeAuthVar '$claudeAuthVar' is not a valid environment variable name."
    }
    # The spawned session is UNATTENDED, so it must never block on an interactive
    # prompt. Headless -p is the only mode that clears ALL of them: it skips the
    # new-worktree trust dialog AND the one-time "Bypass Permissions mode" accept
    # (both are interactive-only). --permission-mode bypassPermissions then keeps it
    # from pausing on per-tool approvals, --no-session-persistence stops parallel
    # sessions colliding on session state, and --verbose streams progress into the
    # tab so it visibly works instead of looking frozen. (An interactive
    # --dangerously-skip-permissions launch still stops at the one-time bypass
    # accept, which is why the tabs opened but never finished.)
    #
    # AUTH: a `claude` child gets no usable OAuth when spawned under the Claude
    # Desktop host (the host holds/refreshes the token in memory and strips the env),
    # so each tab authenticates with an explicit credential read at RUNTIME from the
    # Windows USER env var named by $claudeAuthVar (default ANTHROPIC_API_KEY; set it
    # to CLAUDE_CODE_OAUTH_TOKEN to bill the subscription instead). Only the var NAME
    # touches the command line - the secret never does. Re-reading from the registry
    # also RESTORES the value even when the launching context (Desktop) has stripped
    # it. We FIRST clear every competing Anthropic credential so the chosen one is
    # authoritative regardless of auth precedence - ANTHROPIC_API_KEY outranks
    # CLAUDE_CODE_OAUTH_TOKEN, so an inherited API key would otherwise silently
    # override a subscription token (or 401 if stale). We also drop the inherited
    # CLAUDE_CODE_* session markers so the child starts as a clean top-level session.
    # Delegate the launch-script construction to the chosen CLI's adapter. The adapter
    # receives a context object and RETURNS the launch-script string; the claude adapter
    # reproduces the exact lines this function used to build inline (byte-identical).
    $ctx = @{
        IssueNum     = $issueNum
        WorkPath     = $workPath
        BriefingFile = $briefingFile
        TabTitle     = $tabTitle
        WindowName   = $windowName
        AuthVar      = $claudeAuthVar
    }
    $adapter = Get-CliAdapters | Where-Object { $_.Name -eq $Cli } | Select-Object -First 1
    if (-not $adapter) { throw "Unknown CLI adapter '$Cli'." }
    $launchScript = & $adapter.BuildLaunch $ctx
    # Stamp the reaper fingerprint FIRST (adapter-agnostic prefix), so it is in the
    # environment for the whole script and inherited by the CLI child + grandchild. The
    # marker is validated to a bare token so it can never break out of the '...' literal.
    if ($fleetSession) {
        # Exact marker shape (<issue>-<runId>): digits, a single '-', then alphanumerics.
        # '_' is deliberately NOT allowed - it is a WQL LIKE single-char wildcard, and this
        # token is matched as a process fingerprint by the reaper (a '_' would over-match).
        if ($fleetSession -notmatch '^[0-9]+-[A-Za-z0-9]+$') {
            throw "FleetSession '$fleetSession' is not a valid marker token (<issue>-<runId>)."
        }
        $markerLine   = '$env:ABIOS_FLEET_SESSION=''{0}''' -f $fleetSession
        $launchScript = ($markerLine, $launchScript) -join "`r`n"
    }
    # Session log redirection (#198): capture the whole session stream to a file the
    # -Sessions dashboard tails, while still showing it live in the tab. Start-Transcript
    # is adapter-agnostic (works for every CLI). Opt-in via $logPath so the golden claude
    # parity (which passes none) stays byte-identical. Single-quotes doubled so a path with
    # a ' cannot break the literal.
    if ($logPath) {
        $safeLog = $logPath -replace "'", "''"
        $safeDir = (Split-Path -Parent $logPath) -replace "'", "''"
        $transcript = @(
            ('New-Item -ItemType Directory -Force -Path ''{0}'' *> $null' -f $safeDir)
            ('Start-Transcript -Path ''{0}'' -Append *> $null' -f $safeLog)
        ) -join "`r`n"
        $launchScript = ($transcript, $launchScript) -join "`r`n"
    }
    # The launch script lives next to the briefing (same dir the caller chose).
    $launchScriptFile = Join-Path (Split-Path -Parent $briefingFile) "launch-$issueNum.ps1"
    $safeScriptPath   = $launchScriptFile   # a plain path arg (its own arg element -> Start-Process quotes it)
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{
            launcher         = "wt"
            args             = @('-w', $windowName, 'new-tab', '--title', $tabTitle,
                                 '--startingDirectory', $workPath, 'pwsh', '-NoExit', '-File', $safeScriptPath)
            briefingFile     = $briefingFile
            launchScriptFile = $launchScriptFile
            launchScript     = $launchScript
            fleetSession     = $fleetSession
            usesWt           = $true
        }
    }
    return [PSCustomObject]@{
        launcher         = "pwsh"
        args             = @('-NoExit', '-File', $safeScriptPath)
        briefingFile     = $briefingFile
        launchScriptFile = $launchScriptFile
        launchScript     = $launchScript
        fleetSession     = $fleetSession
        usesWt           = $false
    }
}

# Pick which Windows USER env var each spawned session authenticates with. Pure ->
# testable. An EXPLICIT -ClaudeAuthVar always wins; otherwise prefer the subscription
# OAuth token (CLAUDE_CODE_OAUTH_TOKEN, billed to the plan) when it is present, else
# fall back to the given default (ANTHROPIC_API_KEY, per-token console billing).
function Resolve-ClaudeAuthVar([bool]$explicit, [string]$chosen, [bool]$oauthTokenPresent) {
    if ($explicit) { return $chosen }
    if ($oauthTokenPresent) { return 'CLAUDE_CODE_OAUTH_TOKEN' }
    return $chosen
}

# Spawn (or -Preview) ONE visible Claude session for a started worktree.
function Start-WorktreeSession {
    param(
        [int]$IssueNum, [string]$Repo, [string]$Branch, [string]$WorkPath,
        [string]$ClaudeAuthVar = "ANTHROPIC_API_KEY",
        [string]$Cli = 'claude',
        [string]$FleetSession = '',
        [switch]$StopAtPR,
        [string]$BriefFile = '',
        [string[]]$Irreversible = @(),
    # The human ORDERED this run to finish end-to-end (#530). Travels with the instruction, not with
    # a setting on disk: it is recorded in the brake marker so the merge decision -- taken later,
    # when the facts exist -- still knows what was actually asked for.
    [switch]$EndToEnd,
        # Contract time budget in minutes, written into the brake marker for the hook to enforce (#564).
        [int]$SessionBudgetMinutes = 0,
        [switch]$Preview
    )
    $abios = Get-AbiosDir
    $briefingFile = if ($abios) { Join-Path $abios "briefing-$IssueNum.txt" } else { Join-Path $WorkPath "briefing-$IssueNum.txt" }
    # Redirect this session's stream to logs/issue-<n>.log so the -Sessions dashboard can
    # tail it (Start-Transcript, wired inside the launch script).
    $logPath = Get-SessionLogPath $IssueNum
    $plan  = Build-WorktreeLaunch $IssueNum $WorkPath $briefingFile "abios-parallel" $ClaudeAuthVar $Cli $FleetSession $logPath

    if ($Preview) {
        Write-Host ("  [preview] #{0}: {1} {2}" -f $IssueNum, $plan.launcher, ($plan.args -join ' ')) -ForegroundColor Gray
        Write-Host ("  [preview] #{0} launch script ({1}):" -f $IssueNum, $plan.launchScriptFile) -ForegroundColor DarkGray
        foreach ($ln in ($plan.launchScript -split "`r?`n")) { Write-Host ("             $ln") -ForegroundColor DarkGray }
        return $plan
    }

    if (-not $WorkPath -or -not (Test-Path $WorkPath)) {
        Write-Host "  WARN #${IssueNum}: worktree '$WorkPath' no existe - no se lanza sesion." -ForegroundColor DarkYellow
        return $null
    }
    # ARM THE BRAKE (#516). The briefing below still ASKS the session to stop at a reviewed PR;
    # this marker is what makes the refusal mechanical. The PreToolUse hook
    # (Brake-PreToolUseHook.ps1) finds it by walking up from the session's cwd and denies the
    # irreversible call before it runs. Written only for a real launch: a -Preview must not leave
    # a live control behind, and an unarmed run must not find a stale marker from an armed one.
    try {
        . (Join-Path $PSScriptRoot 'Brake-Guard.ps1')
        $armedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        # A positive budget arms the marker on its own (#564, external review round 2): the hook
        # can only enforce what the marker records, and a launch whose contract does not brake on
        # merge still deserves its time limit. -StopAtPR without a budget arms exactly as before.
        $armIntent = ([bool]$StopAtPR) -or ($SessionBudgetMinutes -gt 0)
        # A marker armed ONLY for the budget declares it (#565 round 6), so an intentionally
        # empty irreversible list stays empty instead of inheriting the anti-tamper full
        # vocabulary - the contract said this run may merge, and the budget must not unsay it.
        # Only when the list is ACTUALLY empty (round 7): with any verb present (say deploy),
        # the declaration would later excuse a hand-emptied list from the anti-tamper fallback.
        $irrClean = @($Irreversible | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $budgetOnly = (-not [bool]$StopAtPR) -and ($SessionBudgetMinutes -gt 0) -and ($irrClean.Count -eq 0)
        $state = Set-BrakeArmedState -WorkPath $WorkPath -Armed $armIntent -Issue $IssueNum `
                    -Irreversible $Irreversible -Branch $Branch -HostName $env:COMPUTERNAME -ArmedAt $armedAt `
                    -EndToEnd ([bool]$EndToEnd) -BudgetMinutes $SessionBudgetMinutes -Repo $Repo -BudgetOnly $budgetOnly
        if ($state -eq 'armed') {
            Write-Host ("  OK  #{0}: freno ARMADO (control real, no solo instruccion) -> {1}" -f $IssueNum, (Get-BrakeMarkerPath -WorkPath $WorkPath)) -ForegroundColor Green
            if ($SessionBudgetMinutes -gt 0) {
                Write-Host ("      presupuesto: {0} min - vencido, el hook solo deja pasar el cierre (handoff/commit/report)" -f $SessionBudgetMinutes) -ForegroundColor DarkGray
            }
        } elseif ($state -eq 'disarmed') {
            Write-Host ("  OK  #{0}: freno DESARMADO (marcador de un run previo retirado)" -f $IssueNum) -ForegroundColor DarkGray
        }
    } catch {
        if ($StopAtPR -or $SessionBudgetMinutes -gt 0) {
            # An unarmed run that believes it is armed is the #440 failure. Say so and refuse to
            # launch rather than spawn a session with a brake that exists only on paper.
            Write-Host "  FAIL #${IssueNum}: no se pudo armar el freno ($_). No se lanza la sesion." -ForegroundColor Red
            return $null
        }
        # A marker we failed to CLEAR only ever over-blocks, so that direction warns and continues.
        Write-Host "  WARN #${IssueNum}: no pude retirar el marcador de freno previo ($_). El merge seguira bloqueado en ese worktree." -ForegroundColor DarkYellow
    }
    # Persist the briefing so the spawned session reads it without command-line quoting.
    Set-Content -LiteralPath $briefingFile -Value (Get-SessionBriefing $IssueNum $Repo $Branch $WorkPath $Cli -StopAtPR:$StopAtPR -BriefFile $BriefFile) -Encoding UTF8
    # Persist the launch script so wt/pwsh runs it via -File (no ';' on wt's command
    # line -> no stray tab-splitting). See Build-WorktreeLaunch header for the why.
    Set-Content -LiteralPath $plan.launchScriptFile -Value $plan.launchScript -Encoding UTF8
    $proc = $null
    try {
        if ($plan.usesWt) { $proc = Start-Process $plan.launcher -ArgumentList $plan.args -PassThru }
        else              { $proc = Start-Process $plan.launcher -ArgumentList $plan.args -WorkingDirectory $WorkPath -PassThru }
        $how = if ($plan.usesWt) { "WT tab 'issue-$IssueNum'" } else { "ventana pwsh" }
        Write-Host ("  OK  #{0}: sesion Claude lanzada ({1}) en {2}" -f $IssueNum, $how, $WorkPath) -ForegroundColor Green
    } catch {
        Write-Host "  FAIL #${IssueNum}: no se pudo lanzar la sesion: $_" -ForegroundColor Red
    }
    # Attach the spawned process so the caller can track its real PID in the registry.
    # NOTE: a 'wt' process forks the terminal host and exits fast, so its PID is not a
    # reliable liveness signal - only the standalone pwsh window's PID is tracked.
    $plan | Add-Member -NotePropertyName process -NotePropertyValue $proc -Force
    return $plan
}

# -- Dashboard helpers (Phase 2 monitor) ---------------------------------------
# Where a spawned session's stream is redirected (log redirection wired in #198).
# Pure given the state dir -> the dashboard reads the tail if the file exists.
function Get-SessionLogPath([int]$Issue) {
    $dir = Get-AbiosDir
    if (-not $dir) { return $null }
    return (Join-Path (Join-Path $dir "logs") "issue-$Issue.log")
}

# Last $Count non-blank lines of a log, oldest-first. Returns @() when the file does
# not exist yet (a session may not have produced output). Reads the whole file - fleet
# logs are small and this stays simple + testable.
function Get-LogTailLines([string]$Path, [int]$Count = 3) {
    # Emits 0..N lines. NOTE: PowerShell unwraps a single-element result on capture
    # ($r = Get-LogTailLines ...), so a caller that indexes must wrap it: @($tail)[0].
    # Show-SessionFleet iterates with foreach, which is safe for a scalar or an array.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    # Drop trailing blank lines so the tail shows real output, not padding.
    $end = $lines.Count - 1
    while ($end -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$end])) { $end-- }
    if ($end -lt 0) { return @() }
    $start = [math]::Max(0, $end - $Count + 1)
    return @($lines[$start..$end])
}

# Live RAM (MB working set) + CPU (cumulative processor seconds) for a session PID.
# Alive=$false when the process is gone. Get-Process is the only reading -> mockable.
function Get-SessionMetrics([int]$SessionPid) {
    $p = Get-Process -Id $SessionPid -ErrorAction SilentlyContinue
    if (-not $p) { return [PSCustomObject]@{ Alive = $false; RamMB = 0; CpuSec = 0 } }
    [PSCustomObject]@{
        Alive  = $true
        RamMB  = [int][math]::Round(($p.WorkingSet64 / 1MB), 0)
        CpuSec = [int][math]::Round(([double]$p.CPU), 0)
    }
}

# One-line CPU/RAM cell for the dashboard. Pure -> unit-testable.
function Format-SessionMetric([object]$Metrics) {
    if (-not $Metrics -or -not $Metrics.Alive) { return "PID muerto" }
    return ("RAM {0} MB | CPU {1}s" -f $Metrics.RamMB, $Metrics.CpuSec)
}

# Monitor the local parallel-session fleet: list every LIVE registered session
# (Read-SessionRegistry prunes dead-PID entries on the way in) with its branch,
# worktree, launch method, CLI, live PID CPU/RAM, log tail and - best-effort - the
# PR opened for its branch.
function Show-SessionFleet {
    $sessions = @(Read-SessionRegistry)
    Write-Host "=== Flota de sesiones activas (esta maquina) ===" -ForegroundColor Cyan
    Write-Host ""
    if ($sessions.Count -eq 0) {
        Write-Host "No hay sesiones vivas registradas en .agentic-board/sessions.json." -ForegroundColor DarkGray
        return
    }
    foreach ($s in ($sessions | Sort-Object issue)) {
        $via = if ($s.via) { $s.via } else { "-" }
        $cli = if ($s.cli) { $s.cli } else { "claude" }
        Write-Host ("  #{0,-4} {1}  [{2}]" -f $s.issue, $s.branch, $cli) -ForegroundColor Yellow
        # Live CPU/RAM for the tracked PID (mockable Get-Process behind Get-SessionMetrics).
        # Best-effort: a provider exception or a bad pid must never crash the dashboard loop.
        $metric = "metricas n/d"
        try { $metric = Format-SessionMetric (Get-SessionMetrics ([int]$s.sessionPid)) } catch { }
        Write-Host ("        PID {0} via {1} | {2} | host {3} | desde {4}" -f $s.sessionPid, $via, $metric, $s.host, $s.started) -ForegroundColor DarkGray
        if ($s.workPath) { Write-Host ("        {0}" -f $s.workPath) -ForegroundColor DarkGray }
        if ($s.repo -and $s.branch) {
            try {
                $pr = @(gh pr list --repo $s.repo --head $s.branch --state all --json number,state,url --limit 1 2>$null | ConvertFrom-Json)
                if ($pr.Count -gt 0) {
                    Write-Host ("        PR #{0} [{1}] {2}" -f $pr[0].number, $pr[0].state, $pr[0].url) -ForegroundColor DarkCyan
                }
            } catch { }
        }
        # Tail of the session's redirected stream, when it has produced output (best-effort).
        try {
            $tail = Get-LogTailLines (Get-SessionLogPath ([int]$s.issue)) 3
            foreach ($ln in $tail) { Write-Host ("        | {0}" -f $ln) -ForegroundColor DarkGray }
        } catch { }
    }
    Write-Host ""
    Write-Host ("Total: {0} sesion(es) viva(s). Las de PID muerto se podaron automaticamente." -f $sessions.Count) -ForegroundColor Cyan
}

# ==============================================================================
# CLI adapter registry: one record per launchable AI CLI. Generalizes the
# previously Claude-only launch path (Build-WorktreeLaunch / Get-SessionBriefing).
# Kind: 'repl' = live tab in the worktree; 'async' = dispatches a cloud task.
# Hooks are scriptblocks so they stay pure/testable and are invoked with &.
# ==============================================================================
function Get-CliAdapters {
    @(
        [PSCustomObject]@{
            Name         = 'claude'
            Command      = 'claude'
            Kind         = 'repl'
            IsDefault    = $true
            InstallCmd   = ''
            # claude is the host CLI running this very script -> always available.
            Probe        = { param($ctx) 'ok' }
            # Build the per-worktree claude launch script. $ctx carries at least
            # BriefingFile + AuthVar. This is the SAME construction Build-WorktreeLaunch
            # used inline before the adapter refactor - kept byte-identical on purpose
            # (see the O'Brien single-quote escaping + the -join "`r`n" below).
            BuildLaunch  = {
                param($ctx)
                # Double any single quote so a briefing path containing ' (valid on Windows, e.g. an
                # O'Brien user folder) can't break out of the single-quoted literal it is embedded in
                # inside the generated launch script (the Get-Content -LiteralPath '...' arg below).
                $safeBrief  = $ctx.BriefingFile -replace "'", "''"
                # Each step on its OWN line (a .ps1 file), so no ';' is ever needed - which is the
                # whole point: ';' on wt's command line would split the tab (see the header note).
                $clearAuth  = 'Remove-Item Env:ANTHROPIC_API_KEY,Env:ANTHROPIC_AUTH_TOKEN,Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue'
                $setAuth    = '$env:{0}=[Environment]::GetEnvironmentVariable(''{0}'',''User'')' -f $ctx.AuthVar
                $clean      = 'Remove-Item Env:CLAUDECODE,Env:CLAUDE_CODE_SESSION_ID,Env:CLAUDE_CODE_CHILD_SESSION,Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue'
                $run        = 'claude -p (Get-Content -Raw -LiteralPath ''{0}'') --permission-mode bypassPermissions --no-session-persistence --verbose' -f $safeBrief
                ($clearAuth, $setAuth, $clean, $run) -join "`r`n"
            }
        }
        [PSCustomObject]@{
            # Replaces the former 'gemini' adapter (#615): Gemini CLI stopped authenticating
            # individual Google accounts on 2026-06-18 - its probe now always returns
            # IneligibleTierError/UNSUPPORTED_CLIENT and Google redirects to Antigravity, so
            # the fleet was routing Docs/Chore work to a CLI that could never come back.
            Name         = 'antigravity'
            Command      = 'agy'
            Kind         = 'repl'
            IsDefault    = $false
            # No npm package - Google ships an install script; the binary lands in
            # %LOCALAPPDATA%\agy\bin. See https://antigravity.google/docs/cli/install
            InstallCmd   = 'irm https://antigravity.google/cli/install.ps1 | iex'
            # One-token probe carrying the SAME headless flag set as BuildLaunch below, so the
            # probe's verdict transfers to the real launch and an auth/quota failure classifies
            # correctly (see Get-CliProbeStatus). The flag makes no difference to THIS prompt -
            # measured 10s without it and 8s with it, exit 0 and 'OK' both ways, because a
            # one-token reply calls no tool - but parity is the point: a probe that exercises a
            # different flag set than the launch can green-light a launch that then fails.
            Probe        = { param($ctx) Invoke-CliProbe @('agy', '-p', 'reply OK', '--dangerously-skip-permissions') }
            BuildLaunch  = {
                param($ctx)
                # agy is told to READ the briefing rather than receiving its content as an
                # argument (what the other adapters do): a briefing carries backticks and
                # quotes, and PowerShell drops embedded quotes when handing an argument to a
                # native .exe. The path still gets the same single-quote doubling as the
                # claude adapter so an O'Brien-style folder can't break out of the literal.
                # --dangerously-skip-permissions is REQUIRED: without it agy soft-denies its
                # own file-read tool call in headless mode and the session starts blind.
                $b = $ctx.BriefingFile -replace "'", "''"
                'agy -p ''Read the file {0} and follow its instructions to the letter.'' --dangerously-skip-permissions' -f $b
            }
        }
        [PSCustomObject]@{
            Name         = 'jules'
            Command      = 'jules'
            Kind         = 'async'
            IsDefault    = $false
            InstallCmd   = 'npm i -g @google/jules'
            # jules is an ASYNC cloud agent: 'jules new' dispatches a session that operates
            # on the REMOTE repo, not this local worktree/branch. Phase-1 limitation: this
            # dispatch is best-effort - there is no local worktree/PR integration yet (the
            # cloud session runs independently of the branch this script checked out). Full
            # worktree/PR round-trip integration is deferred to a later phase.
            # 'jules remote list' returns "Must specify what to list" with exit 0 (a
            # false ok) - '--session' scopes it to a well-formed listing instead.
            Probe        = { param($ctx) Invoke-CliProbe @('jules', 'remote', 'list', '--session') }
            BuildLaunch  = {
                param($ctx)
                $b = $ctx.BriefingFile -replace "'", "''"
                'jules new (Get-Content -Raw -LiteralPath ''{0}'')' -f $b
            }
        }
        [PSCustomObject]@{
            Name         = 'codex'
            Command      = 'codex'
            Kind         = 'repl'
            IsDefault    = $false
            InstallCmd   = 'npm i -g @openai/codex'
            # 'codex login status' is a lightweight auth check (no stdin read, ~2.6s)
            # vs. the old 'codex exec' probe which took ~19.5s and reads stdin.
            Probe        = { param($ctx) Invoke-CliProbe @('codex', 'login', 'status') }
            BuildLaunch  = {
                param($ctx)
                # 'codex exec' reads stdin even with a prompt arg - in a wt tab (TTY
                # stdin) that hangs waiting for input. Piping $null gives it immediate
                # EOF so it proceeds using only the prompt argument.
                $b = $ctx.BriefingFile -replace "'", "''"
                '$null | codex exec (Get-Content -Raw -LiteralPath ''{0}'') --dangerously-bypass-approvals-and-sandbox' -f $b
            }
        }
        [PSCustomObject]@{
            Name         = 'copilot'
            Command      = 'copilot'
            Kind         = 'repl'
            IsDefault    = $false
            InstallCmd   = 'npm i -g @github/copilot'
            Probe        = { param($ctx) Invoke-CliProbe @('copilot', '-p', 'reply OK', '--allow-all') }
            BuildLaunch  = {
                param($ctx)
                $b = $ctx.BriefingFile -replace "'", "''"
                'copilot -p (Get-Content -Raw -LiteralPath ''{0}'') --allow-all' -f $b
            }
        }
    )
}

# Classify a probe outcome into one status word. Pure -> unit-testable.
# Order matters: quota/rate-limit and auth are checked FIRST, even on exit 0 -
# some CLIs (observed live) print an error message but wrongly exit 0, so a
# generic exit-0 "ok" short-circuit would hide a real quota/auth failure.
function Get-CliProbeStatus([int]$ExitCode, [string]$Stderr) {
    $s = "$Stderr".ToLower()
    if ($s -match 'rate.?limit|quota|429|resource.?exhausted|too many requests') { return 'no-quota' }
    if ($s -match '401|403|unauthor|authenticat|not logged in|login required')   { return 'auth' }
    if ($ExitCode -eq 0) { return 'ok' }
    return 'error'
}

# Shared probe runner for 'repl' CLIs that accept a one-shot prompt: run the
# adapter's probe command, capture exit code + stderr, classify. Each adapter's
# Probe scriptblock calls this with its own argument list (filled per CLI in the
# spike tasks). Kept separate so Test-CliAvailability can be tested with a mock Probe.
# Runs the command in a background job with a timeout so a slow/hung CLI (e.g.
# codex exec waiting on stdin) can never block the fleet launch indefinitely.
function Invoke-CliProbe([string[]]$CommandLine, [int]$TimeoutSec = 30) {
    $exe  = $CommandLine[0]
    $rest = @($CommandLine[1..($CommandLine.Count-1)])
    $j = Start-Job { param($e,$a) $o = & $e @a 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o } } -ArgumentList $exe, $rest
    if (Wait-Job $j -Timeout $TimeoutSec) {
        $r = Receive-Job $j; Remove-Job $j -Force
        return Get-CliProbeStatus $r.Exit $r.Out
    }
    Stop-Job $j; Remove-Job $j -Force
    return 'error'
}

# Availability = installed on PATH AND (for repl CLIs) a live probe. Returns
# { Cli, Status, Detail }. Status in ok/no-quota/auth/not-installed/error.
function Test-CliAvailability {
    param([Parameter(Mandatory)][object]$Adapter)
    if (-not (Get-Command $Adapter.Command -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Cli=$Adapter.Name; Status='not-installed'; Detail="$($Adapter.Command) no esta en PATH" }
    }
    $status = & $Adapter.Probe $null
    return [PSCustomObject]@{ Cli=$Adapter.Name; Status=$status; Detail='' }
}

# The v1 safety net: an unavailable chosen CLI silently degrades to claude (the
# always-present default), never aborting the batch. Pure -> unit-testable.
function Resolve-LaunchCli([string]$Chosen, [hashtable]$Availability) {
    if ($Chosen -and $Availability[$Chosen] -eq 'ok') { return $Chosen }
    return 'claude'
}

# Pure core of the picker: given issues + raw choices + live availability, resolve each
# issue to an available CLI (Resolve-LaunchCli enforces fallback). Unit-testable.
function Resolve-IssueCliMap([int[]]$Issues, [hashtable]$Choices, [hashtable]$Availability) {
    $map = @{}
    foreach ($i in $Issues) {
        $chosen = if ($Choices.ContainsKey($i)) { $Choices[$i] } else { 'claude' }
        $map[$i] = Resolve-LaunchCli -Chosen $chosen -Availability $Availability
    }
    return $map
}

# Render the availability table: one colored line per CLI on the console, and the
# same plain line emitted to the pipeline so callers (and tests, via Out-String) can
# capture the rendered text. Green ok / yellow otherwise.
function Show-CliAvailability([hashtable]$Availability) {
    foreach ($cli in ($Availability.Keys | Sort-Object)) {
        $st = $Availability[$cli]
        $color = if ($st -eq 'ok') { 'Green' } else { 'DarkYellow' }
        $line = "  {0,-8} {1}" -f $cli, $st
        Write-Host $line -ForegroundColor $color
        $line
    }
}

# Install a not-installed CLI after explicit user approval, then re-probe. Impure.
function Install-CliOnApproval([object]$Adapter) {
    Write-Host ("  {0} no esta instalada. Comando: {1}" -f $Adapter.Name, $Adapter.InstallCmd) -ForegroundColor Yellow
    $ans = Read-Host "  Instalar ahora? (s/N)"
    if ($ans -notmatch '^[sSyY]') { Write-Host "  Omitida." -ForegroundColor DarkGray; return $false }
    Invoke-Expression $Adapter.InstallCmd
    return ($LASTEXITCODE -eq 0)
}

# Interactive per-issue picker: prints availability, prompts a CLI per issue, then
# resolves through the pure core. Returns the issue->cli map.
function Select-CliPerIssue([int[]]$Issues, [hashtable]$Availability) {
    Show-CliAvailability $Availability | Out-Null
    $available = @($Availability.Keys | Where-Object { $Availability[$_] -eq 'ok' })
    $choices = @{}
    foreach ($i in $Issues) {
        $ans = Read-Host ("  Que asistente trabaja el issue #{0}? [{1}] (Enter = claude)" -f $i, ($available -join '/'))
        if ($ans) { $choices[$i] = $ans.Trim().ToLower() }
    }
    return Resolve-IssueCliMap -Issues $Issues -Choices $choices -Availability $Availability
}

# Pair each started worktree with the CLI the picker resolved for it. Pure.
function Build-FleetPlan([object[]]$Started, [hashtable]$CliMap) {
    foreach ($r in $Started) {
        $cli = if ($CliMap.ContainsKey($r.issue)) { $CliMap[$r.issue] } else { 'claude' }
        [PSCustomObject]@{ issue=$r.issue; repo=$r.repo; branch=$r.branch; workPath=$r.workPath; cli=$cli }
    }
}
# ==============================================================================
# Governor (capacity) + process supervision moved to part files (#575): the same
# functions, dot-sourced so this 3,100-line dispatcher stops holding a job scheduler
# and a process killer inline. Loaded HERE (before the CLI and before the dot-source
# guard) so tests that dot-source Board-Work keep seeing every function.
# ==============================================================================
. (Join-Path $PSScriptRoot 'BoardWork.Capacity.ps1')
. (Join-Path $PSScriptRoot 'BoardWork.Processes.ps1')

# ==============================================================================
# WATCH LAYER (issue #135): auto-detect when the parallel/-Launch sessions finish and
# (opt-in) auto-clean their worktrees + branches + registry entries. Detection is
# read-only polling of observable state; the cleanup is guarded and DI-testable.
# ==============================================================================

# Is a watched session DONE? PURE -> unit-testable. A session finishes when its PR is
# MERGED, its issue is CLOSED, or its host process is dead (the tab exited). Precedence
# (merged > closed > pid-dead) picks the most informative reason. Returns {done, reason}.
# `merged` is NOT cosmetic: it is what makes the branch deletion safe (#273). Only a MERGED
# PR proves the work reached the remote default branch, so only then may the local branch be
# force-deleted. Local ancestry cannot answer this - the repo squash-merges by default, which
# rewrites the commits, so a perfectly merged branch is never an ancestor of main.
#
# The proof must be about THESE commits, not just this branch NAME: branch names are
# deterministic per issue (issue-<n>-<slug>) and a -TakeOver re-run reuses them, so an OLD
# merged PR would otherwise vouch for a NEW session's work (Codex review, PR #275). A merged
# PR whose head is not our branch tip tells us NOTHING about this session, so it neither
# licenses the force-delete NOR completes it - we fall through to the issue/PID signals,
# which still finish a genuinely dead session (with merged=$false -> safe delete). Letting it
# complete would be worse than a leaked branch: cleanup kills the shell and runs
# `git worktree remove --force`, so a stale PR could tear down a LIVE session.
function Get-SessionCompletion {
    param(
        [string]$PrState = '',
        [string]$IssueState = '',
        [bool]$PidAlive = $true,
        [string]$PrHeadOid = '',
        [string]$BranchTip = ''
    )
    if ($PrState -eq 'MERGED' -and $PrHeadOid -and $BranchTip -and $PrHeadOid -eq $BranchTip) {
        return [pscustomobject]@{ done = $true; reason = 'PR merged'; merged = $true }
    }
    if ($IssueState -eq 'CLOSED') { return [pscustomobject]@{ done = $true;  reason = 'issue cerrado';    merged = $false } }
    if (-not $PidAlive)           { return [pscustomobject]@{ done = $true;  reason = 'proceso terminado'; merged = $false } }
    return [pscustomobject]@{ done = $false; reason = 'en progreso'; merged = $false }
}

# Classify the CURRENT branch's disposition for cerrar-ciclo (#302/#650), and route it. PURE:
# every fact is an argument. cerrar-ciclo PERFORMS the disposition's action - it does not merge
# (that keeps the review gate; "ship it" vs "stop for today" stays the human's call), but every
# other step it can safely take on its own, it takes, asking first only where a genuine choice
# exists (reopen a closed PR and keep going, or discard the work).
#   $OnDefault    - the current branch IS the repo default (nothing to close).
#   $Dirty        - 'clean' | 'dirty' | 'unknown'  (unknown = fail closed = treat as dirty).
#   $CommitsAhead - commits on this branch not on its base (0 = nothing committed yet).
#   $Pr           - $null, or { number; state 'OPEN'|'MERGED'|'CLOSED'; merged [bool] }.
# Returns { State; Summary; Action; CanCleanup }. CanCleanup is $true ONLY for a proven-merged
# branch (PR MERGED and this branch is its tip) that is safe to tear down. Action tells the caller
# WHAT to do - 'none' (report only), 'save-handoff' (ask, then Board-Handoff -Save),
# 'run-gate' (no asking needed - it only checks and reports), 'open-pr' (no asking needed -
# opening a PR from already-committed work is low-risk and reversible), or
# 'reopen-or-discard' (ask which - discarding unmerged work is the one truly destructive branch).
# Order matters: an uncommitted working tree is decided BEFORE any PR state (never lose it to a
# cleanup or an auto-performed action).
function Get-CloseLoopDisposition {
    param([bool]$OnDefault, [string]$Dirty = 'clean', [int]$CommitsAhead = 0, $Pr = $null)
    if ($OnDefault) {
        return [pscustomobject]@{ State = 'on-default'; CanCleanup = $false; Action = 'none'
            Summary = "On the default branch - nothing to close. Start work with /board work." }
    }
    if ($Dirty -ne 'clean') {
        return [pscustomobject]@{ State = 'dirty'; CanCleanup = $false; Action = 'save-handoff'
            Summary = "Uncommitted changes present - decide first: commit them, or save a handoff so nothing is lost." }
    }
    if ($Pr -and $Pr.merged) {
        return [pscustomobject]@{ State = 'merged'; CanCleanup = $true; Action = 'cleanup'
            Summary = "PR #$($Pr.number) MERGED and this branch is its tip - safe to tear down the local branch." }
    }
    if ($Pr -and $Pr.state -eq 'MERGED') {
        return [pscustomobject]@{ State = 'merged-advanced'; CanCleanup = $false; Action = 'none'
            Summary = "PR #$($Pr.number) MERGED but this branch moved past its merge commit - NOT deleting (unmerged commits here)." }
    }
    if ($Pr -and $Pr.state -eq 'OPEN') {
        return [pscustomobject]@{ State = 'in-review'; CanCleanup = $false; Action = 'run-gate'
            Summary = "PR #$($Pr.number) is OPEN - running the review gate now." }
    }
    if ($Pr -and $Pr.state -eq 'CLOSED') {
        return [pscustomobject]@{ State = 'closed-unmerged'; CanCleanup = $false; Action = 'reopen-or-discard'
            Summary = "PR #$($Pr.number) was CLOSED without merging - decide: reopen/rescue the work, or discard the branch." }
    }
    if ($CommitsAhead -gt 0) {
        return [pscustomobject]@{ State = 'no-pr'; CanCleanup = $false; Action = 'open-pr'
            Summary = "$CommitsAhead commit(s) on this branch but no PR yet - opening one now." }
    }
    return [pscustomobject]@{ State = 'empty'; CanCleanup = $false; Action = 'none'
        Summary = "On a work branch with no commits and no PR - nothing to close yet." }
}

# Live completion of one registered session: PR state of its head branch + issue state +
# whether the host PID is alive. Best-effort (never throws) so a transient gh failure just
# reads as "still in progress". Wrapped so the watch loop is testable via an injected probe.
#
# Rate-limit protection (#414): when gh reports a rate-limit error we return
# { done=$false; reason='UNKNOWN (rate limit)' } rather than falling through to the PID
# signal. A dead PID after a rate-limit failure looks identical to a verified completion —
# both print "LISTO: proceso terminado" — so the distinction matters.
function Get-SessionLiveStatus {
    param([object]$Session)
    $prState = ''; $issueState = ''; $prHeadOid = ''; $branchTip = ''; $rateLimited = $false
    if ($Session.repo -and $Session.branch) {
        # The tip we would delete. Refs are shared across worktrees, so this resolves from here.
        try { $branchTip = (git rev-parse --verify "$($Session.branch)^{commit}" 2>$null) } catch { }
        try {
            # Several PRs can share a reused branch name, so do not trust "the newest one":
            # prefer the PR whose head IS our tip, and only fall back to the newest for the
            # non-matching case (where a MERGED state proves nothing anyway).
            # Capture stderr (2>&1) to detect rate-limit errors rather than silently falling
            # back to PID liveness as a completion signal (#414).
            $prRaw = @(gh pr list --repo $Session.repo --head $Session.branch --state all --json state,headRefOid --limit 20 2>&1)
            if ($LASTEXITCODE -ne 0 -and ($prRaw | Out-String) -match '(?i)(rate.?limit|0/5000)') {
                $rateLimited = $true
            } elseif ($LASTEXITCODE -eq 0) {
                $prs = @($prRaw | ConvertFrom-Json)
                $mine = $prs | Where-Object { $branchTip -and $_.headRefOid -eq $branchTip } | Select-Object -First 1
                $pick = if ($mine) { $mine } elseif ($prs.Count -gt 0) { $prs[0] } else { $null }
                if ($pick) { $prState = $pick.state; $prHeadOid = $pick.headRefOid }
            }
        } catch { }
    }
    if (-not $rateLimited -and $Session.repo -and $Session.issue) {
        try {
            $issRaw = @(gh issue view $Session.issue --repo $Session.repo --json state 2>&1)
            if ($LASTEXITCODE -ne 0 -and ($issRaw | Out-String) -match '(?i)(rate.?limit|0/5000)') {
                $rateLimited = $true
            } elseif ($LASTEXITCODE -eq 0) {
                $iss = $issRaw | ConvertFrom-Json
                if ($iss) { $issueState = $iss.state }
            }
        } catch { }
    }
    if ($rateLimited) {
        return [pscustomobject]@{ done = $false; reason = 'UNKNOWN (rate limit)'; rateLimited = $true; merged = $false }
    }
    $pidAlive = [bool]($Session.sessionPid -and (Get-Process -Id $Session.sessionPid -ErrorAction SilentlyContinue))
    return Get-SessionCompletion -PrState $prState -IssueState $issueState -PidAlive $pidAlive `
        -PrHeadOid ([string]$prHeadOid) -BranchTip ([string]$branchTip)
}

# Raw registry read WITHOUT the dead-PID pruning that Read-SessionRegistry does. The watch
# loop must use this: a dead host PID is a COMPLETION signal (#135), so pruning it before the
# loop sees it would drop the session before -AutoClean could remove its worktree/branch
# (Codex review, PR #269). Returns @() when the registry is absent/unreadable.
function Read-SessionRegistryRaw {
    $p = Get-SessionRegistryPath
    if (-not $p -or -not (Test-Path $p)) { return @() }
    try { return @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return @() }
}

# Remove one issue's entry from sessions.json (raw read, so a dead-PID pruning pass does
# not interfere). No-op when the registry is absent. Used by auto-clean.
#
# The removed row is ARCHIVED first (#568): removal used to be destruction, so every run's
# wall-clock cost vanished the moment it finished - "nobody, including the tool, knows whether
# a run takes 2 minutes or 40" was literally unanswerable. sessions-history.jsonl keeps the row
# with `ended` and the outcome; best-effort - an archive failure never blocks the cleanup.
function Remove-SessionRegistryEntry {
    param([int]$IssueNum, [string]$Outcome = '')
    $p = Get-SessionRegistryPath
    if (-not $p -or -not (Test-Path $p)) { return }
    try { $entries = @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return }
    $gone = @($entries | Where-Object { [int]$_.issue -eq $IssueNum })
    $kept = @($entries | Where-Object { [int]$_.issue -ne $IssueNum })
    try {
        $histPath = Join-Path (Split-Path $p -Parent) 'sessions-history.jsonl'
        foreach ($g in $gone) {
            $row = [ordered]@{}
            foreach ($prop in $g.PSObject.Properties) { $row[$prop.Name] = $prop.Value }
            $row['ended']   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $row['outcome'] = "$Outcome"
            Add-Content -LiteralPath $histPath -Encoding UTF8 -Value (([pscustomobject]$row) | ConvertTo-Json -Compress -Depth 4)
        }
    } catch { }
    $kept | ConvertTo-Json -Depth 4 -AsArray | Set-Content $p
}

# Parse `git worktree list --porcelain` into objects. The porcelain format is a blank-line
# separated record per worktree: `worktree <path>`, then optional `HEAD <oid>`,
# `branch refs/heads/<name>` | `detached`, `bare`, `locked [<reason>]`, `prunable <reason>`.
# We take `prunable` straight from git rather than guessing: git already knows a registered
# worktree whose directory is gone. PURE over the text -> unit-testable.
#
# Lives here rather than in Board-Doctor.ps1 (its original home, moved in #289) because BOTH the
# doctor and the teardown below need it, and the dot-source only runs doctor -> work.
function Get-WorktreeRecords {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Porcelain)
    $records = @()
    $cur = $null
    foreach ($rawLine in ($Porcelain -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if (-not $line) { if ($cur) { $records += $cur; $cur = $null }; continue }
        if ($line -match '^worktree (.+)$') {
            if ($cur) { $records += $cur }
            $cur = [pscustomobject]@{
                Path = $Matches[1]; Head = ''; Branch = ''; Detached = $false
                Bare = $false; Locked = $false; Prunable = ''
            }
            continue
        }
        if (-not $cur) { continue }
        switch -Regex ($line) {
            '^HEAD (.+)$'             { $cur.Head     = $Matches[1] }
            '^branch refs/heads/(.+)$'{ $cur.Branch   = $Matches[1] }
            '^detached$'              { $cur.Detached = $true }
            '^bare$'                  { $cur.Bare     = $true }
            '^locked'                 { $cur.Locked   = $true }
            '^prunable (.+)$'         { $cur.Prunable = $Matches[1] }
            '^prunable$'              { $cur.Prunable = 'prunable' }
        }
    }
    if ($cur) { $records += $cur }
    return @($records)
}

# Does git STILL register a worktree that HOLDS THIS BRANCH? The question after
# `git worktree remove --force`, and the authority is git's registry - never the disk (#287/#289).
# A removal routinely de-registers the worktree while the directory survives, empty, held by an
# open handle from the shell that was cwd'd inside it; asking Test-Path there answers "still
# present" about something git already let go. An entry git still lists is a real failure; a
# leftover folder is litter.
#
# ASK BY BRANCH, NOT BY PATH, and note that this is the whole point rather than a shortcut. The
# branch is what the caller is about to `git branch -D`, and a registered worktree holding it is
# exactly what makes that fail - so it is the fact worth checking. Matching paths instead means
# comparing two strings from different producers, which FAILS OPEN when they disagree: git emits
# the long `C:/Users/Cristobal/...` while a path routed through %TEMP% can carry the 8.3 short name
# `C:/Users/CRISTO~1/...`. That mismatch reads as "not registered" and licenses the delete. Caught
# exactly that way while testing #287, on a locked worktree git was still listing.
# -Path is kept as a SECONDARY signal for the detached/branchless case; either hit is a block.
# PURE over the text -> unit-testable.
function Test-WorktreeStillRegistered {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Porcelain,
        [string]$Path   = '',
        [string]$Branch = ''
    )
    $norm = { param($p) ($p -replace '\\', '/').TrimEnd('/') }
    $want = if ($Path) { & $norm $Path } else { $null }
    foreach ($w in (Get-WorktreeRecords -Porcelain $Porcelain)) {
        # -eq on strings is case-insensitive, which is right for both a Windows path and the
        # branch name as git echoes it back.
        if ($Branch -and $w.Branch -eq $Branch)       { return $true }
        if ($want   -and (& $norm $w.Path) -eq $want) { return $true }
    }
    return $false
}

# Put a path into the form git prints, so it can be compared with `git worktree list` output at all
# (#291, found by a Codex review of #287/#289).
#
# Test-WorktreeStillRegistered proves "still there" by NAME: branch first, path second. Both can
# miss the SAME registered worktree - the branch signal is blind to a DETACHED worktree, and the
# path signal is blind whenever the two strings disagree for one directory. They disagree for a
# real reason: git prints the LONG form `C:/Users/Cristobal/...`, while a path that travelled
# through %TEMP% (or any 8.3-shortened parent) carries `C:/Users/CRISTO~1/...`. "I could not find
# it" then read as "it is gone" and licensed the delete.
#
# Only the FILESYSTEM can expand a short name, so this is deliberately impure - Get-Item does the
# expansion, and `(Resolve-Path).Path` is NOT a substitute (it preserves the short form; measured).
# When the directory is gone we cannot expand, and we do not need to: git cannot still hold a LIVE
# worktree at a path that does not exist, so falling back to the raw string cannot hide one.
#
# NOTE this is why the fix is a resolver and not a before/after diff of the registry. Proving "some
# worktree left the list" instead of "MY worktree is not in it" sounds safer and is worse: it makes
# an already-de-registered worktree - a stale sessions.json entry, one the user removed by hand -
# unprovable forever, so every retry refuses and the entry leaks. That is exactly the #289 disease,
# and Codex caught this file re-introducing it.
function Resolve-GitPathForm {
    param([string]$Path)
    if (-not $Path) { return '' }
    try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName } catch { return $Path }
}

# Tear down a finished session: kill the tab shell FIRST (the `pwsh -NoExit` left cwd'd
# inside the worktree keeps a handle -> `git worktree remove` fails with Permission denied),
# then remove the worktree, delete the local branch, and prune the registry entry. Returns
# the ordered list of action descriptions; with -DryRun it performs NONE of them (so the
# planned teardown is unit-testable). The PID kill goes through the fail-safe Stop-ProcessTree
# (self + ancestors never killed).
function Invoke-SessionCleanup {
    param([object]$Session, [switch]$DryRun, [switch]$ForceDeleteBranch, [switch]$ForceRemoveWorktree, [switch]$PrMerged)
    $actions = @()
    # Kill ONLY a session whose tracked PID is genuinely its own spawned shell: a standalone
    # `pwsh` window (via='pwsh') records $spawn.process.Id, so killing that releases the
    # worktree handle. A `wt` tab and an in-place -Start record the HOST/launcher PID (the
    # tab's real shell is not tracked), so killing it could take down the host process and
    # unrelated tabs - NEVER do that (Codex review, PR #269). Stop-ProcessTree also guards
    # self + ancestors as a backstop. For wt/in-place, skip the kill and let the worktree
    # removal report a held handle if the untracked shell still has it open.
    if ($Session.sessionPid -and $Session.via -eq 'pwsh') {
        $actions += "kill PID $($Session.sessionPid) (ventana pwsh propia - libera el worktree)"
        if (-not $DryRun) { Stop-ProcessTree -TargetPid ([int]$Session.sessionPid) | Out-Null }
    } elseif ($Session.via -eq 'wt') {
        # Find the tab shell by its launch script: `wt` spawns `pwsh -NoExit -File launch-<n>.ps1`.
        # The issue number in the script path makes the match exact - no risk of killing a shell
        # for a different issue. Find-WtTabShell is mockable in tests (#413).
        $tabShell = Find-WtTabShell $Session.issue
        if ($tabShell) {
            $actions += "kill PID $($tabShell.ProcessId) (pwsh tab shell de wt, launch-$($Session.issue).ps1 - libera el worktree)"
            if (-not $DryRun) {
                Stop-ProcessTree -TargetPid ([int]$tabShell.ProcessId) | Out-Null
                Start-Sleep -Milliseconds 500   # give the OS time to release the directory handle
            }
        } else {
            $actions += "tab shell de wt no encontrado para issue #$($Session.issue) (ya cerrado o no lanzado via wt)"
        }
    }
    # The removal below is --force, which also wipes a DIRTY worktree, destroying whatever the
    # session left uncommitted or untracked (#276). A session that finished WITHOUT merging
    # (gate blocked, agent crashed mid-edit) is exactly the one likely to have dirty files, so
    # refuse and keep everything for a later retry. A merged session is torn down as usual: its
    # work landed, so what remains is scratch. -ForceRemoveWorktree is the deliberate discard.
    # The check is read-only, so it also runs under -DryRun and makes the plan predictive.
    if ($Session.workPath -and -not $PrMerged -and -not $ForceRemoveWorktree -and (Test-Path -LiteralPath $Session.workPath)) {
        $out = @(git -C $Session.workPath status --porcelain 2>&1)
        # FAIL CLOSED: an unreadable worktree (corrupt metadata, index lock, no git) yields no
        # output, which must NOT be read as "clean" - that would hand the --force exactly the
        # case we cannot vouch for (Codex review, PR #277).
        if ($LASTEXITCODE -ne 0) {
            $actions += "WARN conservo el worktree $($Session.workPath) (#$($Session.issue)): no pude comprobar si tiene cambios sin commitear [git status fallo]. Revisalo a mano, o descartalo con -ForceRemoveWorktree"
            return $actions
        }
        $dirty = ($out -join "`n").Trim()
        if ($dirty) {
            $n = @($dirty -split "`n" | Where-Object { $_.Trim() }).Count
            $actions += "WARN conservo el worktree $($Session.workPath) (#$($Session.issue)): $n archivo(s) sin commitear se perderian. Revisalos y commitealos, o descartalos con -ForceRemoveWorktree"
            return $actions
        }
    }
    # Removing the worktree is the step that can genuinely fail (a held handle - see the
    # tab-shell gotcha). Success = GIT no longer registers it. Only then do we delete the branch
    # and prune the registry; otherwise keep BOTH so the leftover is still tracked and a later
    # run can retry (Codex review, PR #269 - never drop tracking on a failed teardown).
    #
    # ASK GIT, NOT THE DISK (#289), and here that is not a nicety - Test-Path made the retry
    # UNABLE TO CONVERGE. With a handle open, `remove --force` de-registers the worktree and still
    # fails to delete the directory, so pass 1 left the folder behind; Test-Path then said "still
    # present" and kept the branch + the registry entry. Every later pass re-ran the removal on a
    # path git had already forgotten ("fatal: not a working tree"), the folder never went away, and
    # the entry leaked FOREVER. The doctor recovered on a second pass only because its inventory
    # comes from `git worktree list`; workPath here comes from the registry, so nothing self-heals.
    # This is the designed case for a `wt` session, whose shell is deliberately never killed above.
    $worktreeGone = $true
    if ($Session.workPath) {
        $actions += "git worktree remove --force $($Session.workPath)"
        if (-not $DryRun) {
            # Resolve BEFORE the removal, while the directory still exists to be resolved: after a
            # successful remove there may be nothing left to expand the short name from (#291).
            $wtPathForGit = Resolve-GitPathForm $Session.workPath
            git worktree remove --force $Session.workPath 2>&1 | Out-Null
            $after = (git worktree list --porcelain 2>$null) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                # FAIL CLOSED: "I could not ask git" is not "it is gone" (the #277 rule).
                $actions += "FAIL no pude releer 'git worktree list' tras el remove - conservo la rama y el registro de #$($Session.issue) para reintentar"
                return $actions
            }
            $worktreeGone = -not (Test-WorktreeStillRegistered -Porcelain $after -Path $wtPathForGit -Branch $Session.branch)
            # Litter, not a blocker: git let it go, so the teardown continues. Try to delete
            # the folder - the shell kill above should have released the directory handle (#413).
            if ($worktreeGone -and (Test-Path -LiteralPath $Session.workPath)) {
                Remove-Item -LiteralPath $Session.workPath -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $Session.workPath) {
                    $actions += "NOTA git solto el worktree pero la carpeta sigue en disco: $($Session.workPath) - borrarla a mano si persiste"
                } else {
                    $actions += "carpeta del worktree eliminada: $($Session.workPath)"
                }
            }
        }
    }
    if (-not $worktreeGone) {
        $actions += "FAIL git sigue registrando el worktree de #$($Session.issue) (handle abierto?) - conservo la rama y el registro para reintentar"
        return $actions
    }
    # Deleting the branch is only safe once the work is somewhere else (#273). -PrMerged is
    # that proof: the PR landed, so the content is on the default branch and GitHub keeps the
    # head commits on the PR regardless - force-delete is correct. We CANNOT ask git instead:
    # the flow squash-merges, which rewrites the commits, so a merged branch is never an
    # ancestor of main and `-d` would refuse every single successful session.
    # Without that proof (issue closed unmerged, gate blocked, agent crashed) the safe `-d`
    # is the point: git refuses on unmerged commits, we keep the branch and WARN instead of
    # destroying the work silently. -ForceDeleteBranch is the deliberate-discard override.
    # A branch that is already gone is not a failure to report - skip it, or the teardown
    # would WARN about "not deleting" something that does not exist and cry wolf.
    $branchExists = $true
    if ($Session.branch -and -not $DryRun) {
        git show-ref --verify --quiet "refs/heads/$($Session.branch)" 2>&1 | Out-Null
        $branchExists = ($LASTEXITCODE -eq 0)
    }
    if ($Session.branch -and $branchExists) {
        $flag = if ($ForceDeleteBranch -or $PrMerged) { '-D' } else { '-d' }
        $actions += "git branch $flag $($Session.branch)"
        if (-not $DryRun) {
            # Quote git's OWN reason: -d refuses mostly for unmerged commits, but also for a
            # branch checked out elsewhere - do not assert a cause we did not verify.
            $why = ((git branch $flag $Session.branch 2>&1) -join ' ').Trim()
            if ($LASTEXITCODE -ne 0) {
                $actions += "WARN conservo la rama $($Session.branch) (#$($Session.issue)): git no la borro [$why]. Revisala antes de descartarla (-ForceDeleteBranch reintenta con -D)"
            }
        }
    }
    $actions += "prune #$($Session.issue) de sessions.json"
    if (-not $DryRun) { Remove-SessionRegistryEntry -IssueNum ([int]$Session.issue) -Outcome $(if ($PrMerged) { 'pr-merged' } else { 'cleaned' }) }
    return $actions
}

# Poll the registered sessions until all finish or the timeout hits. DI-testable: inject
# -GetStatus (per-session probe), -Now (clock) and -Sleep so the loop runs with no gh, no
# real time, no real sleep. With -AutoClean, each session is torn down once as it completes
# (idempotent via a seen-set). Returns {allDone, timedOut, cleaned}.
function Invoke-SessionWatch {
    param(
        [int]$PollSec = 30,
        [int]$TimeoutSec = 1800,
        [switch]$AutoClean,
        [switch]$DryRun,
        [switch]$ForceDeleteBranch,
        [switch]$ForceRemoveWorktree,
        [scriptblock]$GetStatus = { param($s) Get-SessionLiveStatus $s },
        [scriptblock]$ReadSessions = { Read-SessionRegistryRaw },
        [scriptblock]$Now = { Get-Date },
        [scriptblock]$Sleep = { param($sec) Start-Sleep -Seconds $sec },
        # Zombie detection (#414): dead PID + workPath gone from disk → nothing to clean up,
        # safe to prune from sessions.json without a gh call. Injectable for tests.
        [scriptblock]$IsStale = {
            param($s)
            ($s.sessionPid -gt 0) -and
            -not (Get-Process -Id $s.sessionPid -ErrorAction SilentlyContinue) -and
            $s.workPath -and
            -not (Test-Path $s.workPath -PathType Container)
        },
        # Stall detection rides the watch (#565): every -SuperviseEvery cycles the fleet
        # supervisor runs with -Post, so a stalled session gets its [abios-stall] issue comment
        # WITHOUT the human having to remember a separate command. Injectable for tests;
        # 0 disables.
        [int]$SuperviseEvery = 10,
        # Bounded (#565 round 11): the supervisor makes its own gh reads before the bounded
        # posting path, so a hung network call inside it would freeze the watch loop it rides.
        # It runs as a child killed at 120s; its output is replayed so the verdict stays visible.
        [scriptblock]$Supervise = {
            try {
                $sup = Join-Path $PSScriptRoot 'Fleet-Supervisor.ps1'
                $outF = Join-Path ([System.IO.Path]::GetTempPath()) ("abios-sup-" + [guid]::NewGuid().ToString('N') + ".txt")
                $errF = "$outF.err"
                $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',$sup,'-Check','-Post','-ProjectNum',"$ProjectNum") `
                        -WindowStyle Hidden -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
                if (-not $p.WaitForExit(120000)) {
                    try { $p.Kill() } catch { }
                    Write-Host "  WARN supervisor: no termino en 120s - se corto (senal best-effort)." -ForegroundColor DarkYellow
                }
                if (Test-Path $outF) { Get-Content $outF | ForEach-Object { Write-Host $_ }; Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue }
            } catch {
                Write-Host "  WARN supervisor: $_" -ForegroundColor DarkYellow
            }
        }
    )
    $start   = & $Now
    $cleaned = @{}
    # Sessions reported LISTO in a previous cycle: skip re-polling (#414).
    # Reduces API calls from O(registry-size × cycles) to O(pending × cycles).
    $doneSet = @{}
    $cycle   = 0
    while ($true) {
        # Only poll sessions not yet known to be done (#414 — drop from polling set on LISTO).
        $sessions = @(& $ReadSessions | Where-Object { -not $doneSet.ContainsKey([int]$_.issue) })
        if ($sessions.Count -eq 0) {
            Write-Host "  No hay sesiones vivas que observar." -ForegroundColor DarkGray
            return [pscustomobject]@{ allDone = $true; timedOut = $false; cleaned = @($cleaned.Keys) }
        }
        $pending = 0
        foreach ($s in $sessions) {
            # Zombie stale-prune (#414): dead PID + workPath missing → nothing to clean up,
            # skip the gh calls and remove the entry directly.
            if (& $IsStale $s) {
                Write-Host ("  #{0,-4} SKIP: zombie session pruned (PID muerto, worktree ausente)" -f $s.issue) -ForegroundColor DarkGray
                $doneSet[[int]$s.issue] = $true
                if (-not $DryRun) { Remove-SessionRegistryEntry -IssueNum ([int]$s.issue) -Outcome 'stale-prune' }
                continue
            }
            $st = & $GetStatus $s
            if ($st.done) {
                $doneSet[[int]$s.issue] = $true   # don't re-poll this session (#414)
                Write-Host ("  #{0,-4} LISTO: {1}" -f $s.issue, $st.reason) -ForegroundColor Green
                if ($AutoClean -and -not $cleaned.ContainsKey([int]$s.issue)) {
                    $cleaned[[int]$s.issue] = $true
                    # Carry the completion REASON into the teardown: only a merged PR licenses
                    # discarding the branch (#273) or a dirty worktree (#276).
                    foreach ($a in (Invoke-SessionCleanup -Session $s -DryRun:$DryRun -ForceDeleteBranch:$ForceDeleteBranch -ForceRemoveWorktree:$ForceRemoveWorktree -PrMerged:([bool]$st.merged))) {
                        # A kept-branch WARN / failed teardown must not hide in DarkGray noise.
                        $color = if ($a -cmatch '^(WARN|FAIL)') { 'Yellow' } else { 'DarkGray' }
                        Write-Host ("         - {0}" -f $a) -ForegroundColor $color
                    }
                }
            } else {
                $pending++
                # Rate-limited sessions get a yellow warning so the human sees the degraded state (#414).
                $color = if ($st.rateLimited) { 'DarkYellow' } else { 'DarkGray' }
                Write-Host ("  #{0,-4} ...   {1}" -f $s.issue, $st.reason) -ForegroundColor $color
            }
        }
        if ($pending -eq 0) {
            Write-Host "  Todas las sesiones terminaron." -ForegroundColor Green
            return [pscustomobject]@{ allDone = $true; timedOut = $false; cleaned = @($cleaned.Keys) }
        }
        if ((((& $Now) - $start)).TotalSeconds -ge $TimeoutSec) {
            Write-Host ("  Timeout ({0}s) con {1} sesion(es) aun en progreso." -f $TimeoutSec, $pending) -ForegroundColor DarkYellow
            # Final supervisor pass BEFORE leaving (#565 review): with the defaults, the stall
            # threshold (30 min) and the watch timeout (30 min) coincide, so returning here
            # without one last -Post pass meant a full default watch could end with the stall
            # never posted anywhere.
            if ($SuperviseEvery -gt 0) { & $Supervise }
            return [pscustomobject]@{ allDone = $false; timedOut = $true; cleaned = @($cleaned.Keys) }
        }
        $cycle++
        if ($SuperviseEvery -gt 0 -and ($cycle % $SuperviseEvery) -eq 0) { & $Supervise }
        & $Sleep $PollSec
    }
}

# Batch-path wrapper around Invoke-IssueStart. Since #314 made the Status move and the board read
# FAIL CLOSED (throw), a single issue's gh failure would otherwise abort the whole -Parallel foreach
# and skip the summary. Here a throw is converted into a recorded skip (same result shape) so the
# batch keeps going - the documented "skip a failing issue and continue" contract. A single -Start
# deliberately does NOT use this: there the throw should surface.
function Invoke-BatchIssueStart {
    param(
        [int]$IssueNum, $Ctx, [string]$Owner, [string]$Base,
        [switch]$BaseCurrent, [switch]$DryRun, [switch]$IgnoreBlocked, [switch]$TakeOver
    )
    try {
        return Invoke-IssueStart -IssueNum $IssueNum -Ctx $Ctx -Owner $Owner -MakeBranch -PreferWorktree `
                                 -Base $Base -BaseCurrent:$BaseCurrent -DryRunStart:$DryRun `
                                 -IgnoreBlocked:$IgnoreBlocked -TakeOver:$TakeOver
    } catch {
        Write-Host ("  SKIP #{0}: error al iniciar - {1}" -f $IssueNum, $_.Exception.Message) -ForegroundColor Red
        return [PSCustomObject]@{
            issue = $IssueNum; title = ""; repo = ""; branch = ""; workPath = ""
            started = $false; dryRun = [bool]$DryRun; skipped = "error al iniciar: $($_.Exception.Message)"
        }
    }
}

# ==============================================================================
# Main entry. Dot-source guard: when the test harness sets ABIOS_BOARDWORK_DOTSOURCE,
# the script returns here with only the functions defined - no token check, no gh
# calls, no side effects - so the pure helpers can be unit-tested in isolation.
# ==============================================================================
if ($env:ABIOS_BOARDWORK_DOTSOURCE) { return }

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# KILL-LAYER MODES (Phase 2, local-only - no GH_TOKEN needed). Every kill goes
# through the fail-safe Stop-ProcessTree (self + ancestors always excluded) and
# DEFAULTS to a dry-run listing; add -Force to actually kill.
# ==============================================================================
if ($Reap -or $KillAll) {
    $killLive = [bool]$KillAll
    if ($KillAll) {
        $filter = "Name='pwsh.exe' OR Name='node.exe'"
        $procs  = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue | Select-Object ProcessId, CommandLine)
        $candidates = @($procs | Where-Object { (Get-FleetIssueFromCommandLine $_.CommandLine) -gt 0 })
        $label = "TODA la flota (-KillAll)"
    } else {
        $candidates = @(Find-FleetOrphans)
        $label = "huerfanos escapados (-Reap)"
    }
    Write-Host ("=== Fleet reap: {0} ===" -f $label) -ForegroundColor Cyan
    if ($candidates.Count -eq 0) { Write-Host "  No hay candidatos. Nada que hacer." -ForegroundColor DarkGray; exit 0 }
    $plan = @(Invoke-FleetReap -Candidates $candidates -KillLive:$killLive -DryRun)
    foreach ($r in $plan) {
        $cand  = $candidates | Where-Object { [int]$_.ProcessId -eq $r.Pid } | Select-Object -First 1
        $issue = if ($cand) { Get-FleetIssueFromCommandLine $cand.CommandLine } else { 0 }
        if ($r.Refused) { Write-Host ("  #{0,-4} PID {1} PROTEGIDO: {2}" -f $issue, $r.Pid, $r.Reason) -ForegroundColor DarkYellow }
        else            { Write-Host ("  #{0,-4} PID {1} -> {2}" -f $issue, $r.Pid, $r.Command) -ForegroundColor Yellow }
    }
    $killable = @($plan | Where-Object { -not $_.Refused })
    if (-not $Force) {
        Write-Host ""
        Write-Host ("  {0} matable(s), {1} protegido(s). Re-ejecuta con -Force para matarlos." -f $killable.Count, ($plan.Count - $killable.Count)) -ForegroundColor Cyan
        exit 0
    }
    $done = @(Invoke-FleetReap -Candidates $candidates -KillLive:$killLive)
    Write-Host ("  Matados: {0} de {1} candidato(s)." -f @($done | Where-Object { $_.Killed }).Count, $done.Count) -ForegroundColor Green
    exit 0
}

if ($Stop -gt 0) {
    $sess = @(Read-SessionRegistry | Where-Object { $_.issue -eq $Stop }) | Select-Object -First 1
    if (-not $sess) { Write-Host "  No hay sesion viva registrada para #$Stop." -ForegroundColor DarkYellow; exit 0 }
    $r = Stop-ProcessTree -TargetPid ([int]$sess.sessionPid) -DryRun:(-not $Force)
    if ($r.Refused)  { Write-Host ("  #{0} PID {1} PROTEGIDO: {2}" -f $Stop, $r.Pid, $r.Reason) -ForegroundColor DarkYellow; exit 0 }
    if (-not $Force) { Write-Host ("  #{0} -> {1}`n  (re-ejecuta con -Force para matar)" -f $Stop, $r.Command) -ForegroundColor Cyan; exit 0 }
    Write-Host ("  #{0} PID {1} killed={2}" -f $Stop, $r.Pid, $r.Killed) -ForegroundColor Green
    exit 0
}

if ($Relaunch -gt 0) {
    $sess = @(Read-SessionRegistry | Where-Object { $_.issue -eq $Relaunch }) | Select-Object -First 1
    if (-not $sess) { Write-Host "  No hay sesion registrada para #$Relaunch." -ForegroundColor DarkYellow; exit 0 }
    $cli = if ($sess.cli) { $sess.cli } else { 'claude' }
    if (-not $Force) {
        Write-Host ("  Relaunch #{0}: mataria PID {1} y relanzaria [{2}] en {3}." -f $Relaunch, $sess.sessionPid, $cli, $sess.workPath) -ForegroundColor Cyan
        Write-Host "  (re-ejecuta con -Force para ejecutar)" -ForegroundColor DarkGray
        exit 0
    }
    # Honor the guarded stop: if it was refused (self/ancestor, or fail-closed no-map) the
    # old session is still alive - do NOT relaunch or rewrite the registry.
    $stopRes = Stop-ProcessTree -TargetPid ([int]$sess.sessionPid)
    if ($stopRes.Refused) {
        Write-Host ("  Relaunch #{0} ABORTADO: no se pudo detener PID {1}: {2}" -f $Relaunch, $stopRes.Pid, $stopRes.Reason) -ForegroundColor Red
        exit 1
    }
    $oauthPresent = [bool][System.Environment]::GetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN','User')
    $authVar      = Resolve-ClaudeAuthVar $PSBoundParameters.ContainsKey('ClaudeAuthVar') $ClaudeAuthVar $oauthPresent
    $marker       = New-FleetSessionMarker $Relaunch (New-FleetRunId)
    $relaunchBrake = Resolve-LaunchBrake -AllowMerge ([bool]$AllowMerge) `
        -StopAtPRBound $PSBoundParameters.ContainsKey('StopAtPR') -StopAtPR ([bool]$StopAtPR)
    $spawn = Start-WorktreeSession -IssueNum $Relaunch -Repo $sess.repo -Branch $sess.branch -WorkPath $sess.workPath -ClaudeAuthVar $authVar -Cli $cli -FleetSession $marker -StopAtPR:$relaunchBrake -BriefFile $BriefFile -Irreversible $Irreversible -EndToEnd:$EndToEnd -SessionBudgetMinutes $BudgetMinutes
    # Start-WorktreeSession returns $null on a failed/missing-worktree spawn. Registering
    # then would fall back to the coordinator PID and poison the registry - so only record a
    # session that actually launched.
    if (-not $spawn) {
        Write-Host ("  Relaunch #{0} FALLO: el worktree no existe o no se pudo lanzar - registro intacto." -f $Relaunch) -ForegroundColor Red
        exit 1
    }
    $via = if ($spawn.usesWt) { 'wt' } else { 'pwsh' }
    if ($spawn.process -and -not $spawn.usesWt) { Write-SessionRegistryEntry -IssueNum $Relaunch -SessionPid $spawn.process.Id -Via $via -Cli $cli -FleetSession $marker }
    else { Write-SessionRegistryEntry -IssueNum $Relaunch -Via $via -Cli $cli -FleetSession $marker }
    Write-Host ("  Relaunched #{0} [{1}]." -f $Relaunch, $cli) -ForegroundColor Green
    exit 0
}

# ==============================================================================
# PREFERENCE MODE: -PreferGroupedPRs on|off|auto  -> record this repo's standing
# answer about grouped PRs (#662) and stop. It is a decision, not a run: writing it
# and then also listing the board would bury the confirmation the user needs to see.
# ==============================================================================
if ($PreferGroupedPRs) {
    $cfgPath = Get-BoardConfigPath
    if (-not $cfgPath) {
        Write-Host "No estoy dentro de un repo git, asi que no hay donde guardar la preferencia." -ForegroundColor Red
        exit 1
    }
    $value = switch ($PreferGroupedPRs) {
        'on'   { $true }
        'off'  { $false }
        'auto' { $null }
    }
    Set-BoardConfigValue -Path $cfgPath -Key 'preferGroupedPRs' -Value $value | Out-Null

    # Read it BACK. The whole point of a recorded preference is that it survives, and a
    # write this script only claims to have done is the failure this repo keeps finding.
    $check   = Read-BoardConfig -Path $cfgPath
    $posture = Resolve-GroupingPosture $check.config
    $expected = switch ($PreferGroupedPRs) { 'on' { 'always' } 'off' { 'never' } 'auto' { 'auto' } }
    if (-not $check.ok -or $posture -ne $expected) {
        Write-Host "No pude guardar la preferencia: la volvi a leer y no dice lo que escribi." -ForegroundColor Red
        if ($check.error) { Write-Host "  $($check.error)" -ForegroundColor DarkGray }
        exit 1
    }

    $said = switch ($posture) {
        'always' { 'juntar en un solo PR los que se solapen, sin preguntarte cada vez' }
        'never'  { 'un PR por issue, sin agrupar' }
        'auto'   { 'proponerte juntarlos cuando se solapen, y lo decides tu' }
    }
    Write-Host "=== Preferencia del repo guardada ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  De ahora en adelante: $said." -ForegroundColor Green
    Write-Host "  Queda con el repo, asi que no hay que repetirlo cada sesion." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# Everything BELOW this line talks to GitHub. -PreferGroupedPRs does not: it records a local
# decision in the repo's own config file, so it runs FIRST and never demands a token it has no
# use for - otherwise a machine with no PAT configured could not set the preference at all.
# -- Token (respect GH_TOKEN if gh-account already set it) ---------------------
if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# -Base and -BaseCurrent contradict each other; silently honouring one would put the
# branch on a base the caller did not ask for - the exact class of bug #294 was.
if ($Base -and $BaseCurrent) { throw "-Base and -BaseCurrent are mutually exclusive: pick the ref, or the current HEAD." }

# -StartGroup is a third, distinct way to start issues (#633) - combining it with -Start or
# -Parallel would leave it ambiguous which mode actually ran.
$groupQueue = @(Get-ParallelQueue $StartGroup)
if ($groupQueue.Count -gt 0 -and ($Start -gt 0 -or $Parallel.Count -gt 0)) {
    throw "-StartGroup es mutuamente exclusivo con -Start y -Parallel: son tres modos distintos de arrancar issues."
}

# ==============================================================================
# LOCK MODE: -Lock <n> / -Unlock <n>  -> in ONE step mark an issue owned-elsewhere
# (post the [abios-claim] fingerprint, move Status, AND assign the owner) WITHOUT
# starting or branching it locally (issue #236). Assigning the owner is what makes
# the lock EFFECTIVE: it puts the issue in the exact In Progress + assigned state
# that Invoke-IssueStart's existing multi-session guard refuses (a status move alone
# would not - that guard requires an assignee). Symmetric: -Unlock posts an UNLOCK
# claim, moves Status back to Backlog, and unassigns the owner.
# ==============================================================================
if ($Lock -gt 0 -or $Unlock -gt 0) {
    if ($ProjectNum -le 0) { throw "-Lock/-Unlock necesitan -ProjectNum <n> para mover el Status." }
    $lockUrl = Get-BoardUrl $ProjectNum
    $locking = ($Lock -gt 0)
    $n       = if ($locking) { $Lock } else { $Unlock }
    $ctx     = Resolve-BoardStatus $Owner $ProjectNum
    $item    = Get-BoardItem $ctx.projectId $n
    if (-not $item) { throw "Issue #$n no esta en el board #$ProjectNum." }
    $repo       = $item.content.repository.nameWithOwner
    $note       = if ($locking) { 'LOCK' } else { 'UNLOCK' }
    # Resolve through the vocabulary: on a legacy board the release target is 'Todo', and
    # the old literal 'Backlog' lookup returned $null - the unlock then posted its comment
    # and unassigned but left the item stranded in In Progress (Codex review, PR #279).
    $targetName = if ($locking) { 'In Progress' } else { 'Backlog' }
    $targetOpt  = if ($locking) { $ctx.inProgId } else { Resolve-StatusOptionId $ctx.statusNode 'Backlog' }
    if (-not $targetOpt) {
        throw "El board #$ProjectNum no tiene una opcion de Status para '$targetName' (ni un nombre legacy equivalente). Aplica el preset con /board field apply en."
    }
    $fingerprint = Format-ClaimFingerprint -Note $note -Computer $env:COMPUTERNAME -ProcessId $PID -Date (Get-Date -Format 'yyyy-MM-dd HH:mm')

    $assignVerb = if ($locking) { "asignar a $Owner" } else { "desasignar a $Owner" }
    if ($DryRun) {
        Write-Host ("DRY-RUN: #{0} -> Status {1} + {2} + comentario [abios-claim] {3} (no ejecutado)." -f $n, $targetName, $assignVerb, $note) -ForegroundColor Gray
        Write-Host "Board: $lockUrl" -ForegroundColor Cyan
        exit 0
    }

    # The [abios-claim] comment IS the lock marker other sessions read - if it silently fails to
    # post, -Start would not see the lock. Fail closed (throw) so a lock that did not happen is
    # never reported as posted (#314).
    $null = Invoke-Gh -GhArgs @('issue','comment',"$n",'--repo',$repo,'--body',$fingerprint) `
                      -What "postear el comentario [abios-claim] en #$n"
    if ($targetOpt) {
        # -Graphql throws on exit OR errors[]: the multi-session LOCK the user believes protects
        # their work must not be reported "OK" when the status move silently no-op'd (#314).
        $lockStatusMutation = '
mutation($proj:ID!,$item:ID!,$field:ID!,$opt:String!) {
  updateProjectV2ItemFieldValue(input:{
    projectId:$proj, itemId:$item, fieldId:$field,
    value:{singleSelectOptionId:$opt}
  }) { projectV2Item { id } }
}'
        $null = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$lockStatusMutation",'-f',"proj=$($ctx.projectId)",'-f',"item=$($item.id)",'-f',"field=$($ctx.statusNode.id)",'-f',"opt=$targetOpt") `
                          -What "mover #$n a $targetName" -Graphql
        Write-Host ("OK  #{0} Status -> {1}" -f $n, $targetName) -ForegroundColor Green
    } else {
        Write-Host ("WARN el board no tiene la opcion '{0}' en Status - solo se posteo el comentario {1}." -f $targetName, $note) -ForegroundColor DarkYellow
    }
    # Assign (lock) / unassign (unlock) the owner so the In Progress + assigned state
    # that Invoke-IssueStart's guard checks for is real - a status move alone is not
    # enough to make -Start refuse (Codex review, PR #268). Routed through Invoke-Gh so the
    # warn actually fires on a real failure (a bare native non-zero never threw) (#314).
    try {
        $method = if ($locking) { 'POST' } else { 'DELETE' }
        $null = Invoke-Gh -GhArgs @('api',"repos/$repo/issues/$n/assignees",'-X',$method,'-F',"assignees[]=$Owner") `
                          -What "$assignVerb en #$n"
        Write-Host ("OK  #{0} {1}" -f $n, $assignVerb) -ForegroundColor Green
    } catch {
        Write-Host ("WARN no se pudo {0}: {1}" -f $assignVerb, $_) -ForegroundColor DarkYellow
    }
    $verb = if ($locking) { 'bloqueado (otra sesion lo trabaja)' } else { 'desbloqueado (liberado)' }
    Write-Host ("OK  #{0} {1} - [abios-claim] {2} posteado." -f $n, $verb, $note) -ForegroundColor Green
    Write-Host "Board: $lockUrl" -ForegroundColor Cyan
    exit 0
}

# ==============================================================================
# CLOSE-LOOP MODE: -CloseLoop  -> classify the CURRENT branch and route it to the
# right disposition (#302). It PROPOSES the next step for every state and performs
# exactly ONE action: tearing down a proven-merged local branch in place - the
# single-session equivalent of the fleet's -AutoClean, which an interactive session
# never reaches. It never merges (that has the review gate) and never touches a
# dirty tree. Operates on the current branch only; the repo-wide sweep is /board doctor.
# ==============================================================================
if ($CloseLoop) {
    $repo = $Repo
    if (-not $repo) { try { $repo = Get-RepoFromOrigin } catch { $repo = '' } }
    $curBranch = (git branch --show-current 2>$null)
    if (-not $curBranch) { throw "HEAD detached - cerrar-ciclo opera sobre la rama actual." }

    $baseRef      = Resolve-IssueBaseRef $repo
    $defaultShort = if ($baseRef -match '/') { ($baseRef -split '/', 2)[1] } else { $baseRef }
    $onDefault    = [bool]($defaultShort -and $curBranch -eq $defaultShort)

    # Dirty state fails closed: an unreadable working tree is treated as dirty, never as clean,
    # so cleanup can never run over work it could not vouch for.
    $porcelain = git status --porcelain 2>$null
    $dirty = if ($LASTEXITCODE -ne 0) { 'unknown' } elseif ($porcelain) { 'dirty' } else { 'clean' }

    $ahead = 0
    if ($baseRef) {
        $c = git rev-list --count "$baseRef..HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) { $ahead = [int]$c }
    }

    # The PR whose head IS our tip (a reused branch name can carry several); a MERGED verdict
    # requires the tip match, via the same Get-SessionCompletion predicate the teardown uses.
    $pr = $null
    if ($repo) {
        try {
            $tip = (git rev-parse --verify HEAD 2>$null)
            $prs = @(gh pr list --repo $repo --head $curBranch --state all --json number,state,headRefOid --limit 20 2>$null | ConvertFrom-Json)
            $mine = $prs | Where-Object { $tip -and $_.headRefOid -eq $tip } | Select-Object -First 1
            $pick = if ($mine) { $mine } elseif ($prs.Count -gt 0) { $prs[0] } else { $null }
            if ($pick) {
                $verdict = Get-SessionCompletion -PrState $pick.state -PrHeadOid ([string]$pick.headRefOid) -BranchTip ([string]$tip)
                $pr = [pscustomobject]@{ number = $pick.number; state = $pick.state; merged = [bool]$verdict.merged }
            }
        } catch { }
    }

    $disp = Get-CloseLoopDisposition -OnDefault $onDefault -Dirty $dirty -CommitsAhead $ahead -Pr $pr

    # Needed by more than one action below (save-handoff, open-pr, and the existing cleanup path) -
    # resolved once, from the session registry first (authoritative) and the branch name as fallback.
    $entry    = @(Read-SessionRegistryRaw | Where-Object { $_.branch -eq $curBranch }) | Select-Object -First 1
    $issueNum = if ($entry) { [int]$entry.issue } elseif ($curBranch -match '^issue-(\d+)') { [int]$Matches[1] } else { 0 }

    Write-Host ("=== cerrar-ciclo  ({0})  rama {1} ===" -f $(if ($repo) { $repo } else { '(repo desconocido)' }), $curBranch) -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Estado: {0}" -f $disp.State) -ForegroundColor Yellow
    Write-Host ("  {0}" -f $disp.Summary)

    switch ($disp.Action) {
        'cleanup' {
            # The GAP (#302): a proven-merged local branch, torn down in place. Squash-merge means
            # `git branch -d` would refuse (it reads as unmerged), so a PROVEN merge licenses `-D`.
            # Switch off the branch first (you cannot delete the one you are on), never on a dirty tree.
            if ($DryRun) {
                Write-Host ""
                Write-Host ("  DRY-RUN: cambiaria a '{0}', borraria la rama '{1}' (-D, merge probado) y purgaria su entrada de sesion." -f $defaultShort, $curBranch) -ForegroundColor Yellow
                exit 0
            }
            $go = [bool]$Force
            if (-not $go) {
                $ans = Read-Host ("Este trabajo ya se mergeo (PR #{0}). Te cambio a '{1}' y limpio la rama vieja '{2}'? (s/n)" -f $pr.number, $defaultShort, $curBranch)
                $go = ($ans -match '^(s|si|y|yes)$')
            }
            if (-not $go) { Write-Host "  Cancelado - la rama se conserva." -ForegroundColor DarkGray; exit 0 }

            if (-not $defaultShort) { throw "No pude resolver la rama por defecto para cambiarme antes de borrar." }
            git checkout $defaultShort 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "No pude cambiar a '$defaultShort' (working tree ocupado?) - no borro la rama." }
            git pull --ff-only --quiet 2>&1 | Out-Null
            git branch -D $curBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host ("  WARN no pude borrar '{0}' (checkouteada en otro worktree?) - conservada." -f $curBranch) -ForegroundColor DarkYellow
            } else {
                Write-Host ("  OK  rama '{0}' borrada; ahora en '{1}'." -f $curBranch, $defaultShort) -ForegroundColor Green
            }
            if ($issueNum -gt 0) {
                Remove-SessionRegistryEntry -IssueNum $issueNum -Outcome 'close-loop'
                Write-Host ("  OK  entrada de sesion del issue #{0} purgada." -f $issueNum) -ForegroundColor DarkGray
            }
        }
        'save-handoff' {
            # Non-destructive by construction: a handoff never touches the working tree, so there is
            # nothing here that -DryRun needs to preview or -Force needs to skip past.
            $ans = Read-Host "Tenes cambios sin guardar. Guardo un handoff para retomar despues? (s/n)"
            if ($ans -match '^(s|si|y|yes)$') {
                if ($issueNum -le 0) {
                    Write-Host "  No pude identificar el issue de esta rama - guarda el handoff a mano indicando el numero." -ForegroundColor DarkYellow
                } elseif ($DryRun) {
                    Write-Host ("  DRY-RUN: guardaria un handoff para el issue #{0}." -f $issueNum) -ForegroundColor Yellow
                } else {
                    & (Join-Path $PSScriptRoot 'Board-Handoff.ps1') -Save -Issue $issueNum -Repo $repo -TokenVar $TokenVar
                }
            } else {
                Write-Host "  Ok - seguis trabajando, no se guardo nada." -ForegroundColor DarkGray
            }
        }
        'run-gate' {
            # Purely informational (checks + reports; never merges), so it needs no confirmation -
            # the only question the gate can raise ("mergeo?") stays with the human, downstream.
            if ($DryRun) {
                Write-Host ("  DRY-RUN: correria el review gate sobre el PR #{0}." -f $pr.number) -ForegroundColor Yellow
            } else {
                & (Join-Path $PSScriptRoot 'Board-ReviewGate.ps1') -Repo $repo -PR $pr.number -TokenVar $TokenVar
            }
        }
        'open-pr' {
            # Opening a PR from work already committed is the obvious next step and easy to reverse
            # (close it again) - no question needed, matching how 'merged'-cleanup is the only path
            # that still asks (deleting a branch is the one step here that is not trivially undone).
            if ($issueNum -le 0) {
                Write-Host "  No pude identificar el issue de esta rama - abre el PR a mano indicando el numero." -ForegroundColor DarkYellow
            } elseif ($DryRun) {
                Write-Host ("  DRY-RUN: abriria el PR para el issue #{0}." -f $issueNum) -ForegroundColor Yellow
            } else {
                & (Join-Path $PSScriptRoot 'New-BoardPR.ps1') -Issue $issueNum -Repo $repo -TokenVar $TokenVar
            }
        }
        'reopen-or-discard' {
            # The one truly destructive branch besides 'cleanup': discarding here throws away
            # UNMERGED work, unlike 'cleanup' which only ever deletes a branch already proven safe
            # by a merged PR. The question spells that out instead of hiding it behind git jargon.
            if ($DryRun) {
                Write-Host ("  DRY-RUN: preguntaria si reabrir el PR #{0} o descartar la rama '{1}' (esto SI perderia trabajo sin mergear)." -f $pr.number, $curBranch) -ForegroundColor Yellow
                exit 0
            }
            $ans = Read-Host ("El PR #{0} se cerro sin mergear. Lo reabro y seguimos, o descarto la rama '{1}' para siempre? [reabrir/descartar]" -f $pr.number, $curBranch)
            if ($ans -match '^(reabrir|reopen|r)$') {
                try {
                    $null = Invoke-Gh -GhArgs @('pr','reopen',"$($pr.number)",'--repo',$repo) -What "reabrir el PR #$($pr.number)"
                    Write-Host ("  OK  PR #{0} reabierto - segui trabajando en esta rama." -f $pr.number) -ForegroundColor Green
                } catch {
                    Write-Host "  WARN no pude reabrir el PR - revisalo a mano." -ForegroundColor DarkYellow
                }
            } elseif ($ans -match '^(descartar|discard|d)$') {
                $confirm = Read-Host ("Esto borra el trabajo sin mergear de '{0}' PARA SIEMPRE. Seguro? (s/n)" -f $curBranch)
                if ($confirm -match '^(s|si|y|yes)$') {
                    if (-not $defaultShort) { throw "No pude resolver la rama por defecto para cambiarme antes de borrar." }
                    git checkout $defaultShort 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "No pude cambiar a '$defaultShort' (working tree ocupado?) - no borro la rama." }
                    git branch -D $curBranch 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host ("  WARN no pude borrar '{0}' (checkouteada en otro worktree?) - conservada." -f $curBranch) -ForegroundColor DarkYellow
                    } else {
                        Write-Host ("  OK  rama '{0}' descartada; ahora en '{1}'." -f $curBranch, $defaultShort) -ForegroundColor Green
                        if ($issueNum -gt 0) { Remove-SessionRegistryEntry -IssueNum $issueNum -Outcome 'close-loop-discard' }
                    }
                } else {
                    Write-Host "  Cancelado - la rama se conserva." -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  No entendi la respuesta - la rama se conserva sin cambios." -ForegroundColor DarkGray
            }
        }
        default { } # 'none': the Summary above already said everything there is to say.
    }
    exit 0
}

# ==============================================================================
# MODE 0: -Sessions  -> monitor the local parallel-session fleet
#         -Sessions -Watch [-AutoClean]  -> block until the sessions finish, then
#         (opt-in) tear down their worktrees/branches/registry entries (issue #135).
# ==============================================================================
if ($Sessions) {
    Show-BranchDrift
    Show-SessionFleet
    if ($Watch) {
        Write-Host ""
        Write-Host ("=== Watch (poll {0}s, timeout {1}s{2}) ===" -f $WatchPollSec, $WatchTimeoutSec, $(if ($AutoClean) { ', auto-clean' } else { '' })) -ForegroundColor Cyan
        Invoke-SessionWatch -PollSec $WatchPollSec -TimeoutSec $WatchTimeoutSec -AutoClean:$AutoClean -DryRun:$DryRun -ForceDeleteBranch:$ForceDeleteBranch -ForceRemoveWorktree:$ForceRemoveWorktree | Out-Null
    }
    exit 0
}

# -Watch without -Sessions and without a -Parallel run: still a valid standalone watch.
if ($Watch -and $Parallel.Count -eq 0) {
    Write-Host ("=== Watch (poll {0}s, timeout {1}s{2}) ===" -f $WatchPollSec, $WatchTimeoutSec, $(if ($AutoClean) { ', auto-clean' } else { '' })) -ForegroundColor Cyan
    Invoke-SessionWatch -PollSec $WatchPollSec -TimeoutSec $WatchTimeoutSec -AutoClean:$AutoClean -DryRun:$DryRun -ForceDeleteBranch:$ForceDeleteBranch -ForceRemoveWorktree:$ForceRemoveWorktree | Out-Null
    exit 0
}

# ==============================================================================
# MODE 1: -ListBoards  -> every board with its pending count
# ==============================================================================
if ($ListBoards) {
    if ($Repo) {
        # Current-repo scope: only boards LINKED to this repository
        Write-Host "=== Boards vinculados a $Repo (contando pendientes) ===" -ForegroundColor Cyan
        Write-Host ""
        $rp = $Repo -split "/"
        # -Graphql fails closed: a read failure must not read as "the repo has no linked boards"
        # and send the user to /board init to create a DUPLICATE of a board it could not see (#314).
        $linkedQuery = '
query($o:String!, $r:String!) {
  repository(owner:$o, name:$r) {
    projectsV2(first:20) {
      nodes {
        number title closed
        owner { ... on User { login } ... on Organization { login } }
      }
    }
  }
}'
        $linked = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$linkedQuery",'-f',"o=$($rp[0])",'-f',"r=$($rp[1])") `
                            -What "leer los boards vinculados a $Repo" -Graphql
        $boards = @($linked.data.repository.projectsV2.nodes |
                    Where-Object { -not $_.closed -and $_.title -notmatch '(?i)backup' } |
                    ForEach-Object { [PSCustomObject]@{ number = $_.number; title = $_.title; ownerLogin = $_.owner.login } })
        if ($boards.Count -eq 0) {
            Write-Host "El repo $Repo no tiene boards vinculados. Crea/vincula uno con /board init." -ForegroundColor Yellow
            exit 0
        }
    } else {
        # Account scope: every board of the owner
        Write-Host "=== Boards de $Owner (contando pendientes, puede tardar unos segundos) ===" -ForegroundColor Cyan
        Write-Host ""
        $projects = (Invoke-Gh -GhArgs @('project','list','--owner',$Owner,'--format','json','--limit','30') `
                               -What "listar los boards de $Owner" -Json).projects
        $boards   = @($projects | Where-Object { $_.title -notmatch '(?i)backup' } |
                      ForEach-Object { [PSCustomObject]@{ number = $_.number; title = $_.title; ownerLogin = $Owner } })
        if ($boards.Count -eq 0) { Write-Host "No hay boards para $Owner."; exit 0 }
    }

    $rows = @()
    foreach ($b in $boards) {
        try {
            # Get-BoardItems throws on a failed read (caught below -> honest "?"): a bare read would
            # yield $null under pwsh 7 and print "pendientes: 0", a false clean for that board (#314).
            # It ALSO reports a capped read, which the old --limit 200 swallowed: this picker
            # under-counted every board past the cap and so looked emptier than it was (#484).
            $read    = Get-BoardItems -Number $b.number -Owner $b.ownerLogin `
                                      -What "listar los items del board #$($b.number)"
            $pending = @($read.Items | Where-Object { Test-Pending $_ }).Count
            $total   = $read.Read
            $trunc   = $read.Truncated
        } catch {
            $pending = "?"; $total = "?"; $trunc = $false
        }
        $rows += [PSCustomObject]@{
            Num       = $b.number
            Titulo    = $b.title
            Pendientes = $pending
            Items     = $total
            Trunc     = $trunc
            Url       = "https://github.com/users/$($b.ownerLogin)/projects/$($b.number)"
        }
    }

    # Boards with pending work first, most pending on top
    $rows = $rows | Sort-Object -Property @{Expression={ if ($_.Pendientes -is [int]) { -$_.Pendientes } else { 1 } }}

    foreach ($r in $rows) {
        $color = if ($r.Pendientes -is [int] -and $r.Pendientes -gt 0) { "Yellow" } else { "DarkGray" }
        # A capped read makes both numbers a FLOOR, not a count - so they are rendered as "N+".
        # Printing a bare "pendientes: 0" off a short read is the whole bug (#484).
        $sfx   = if ($r.Trunc) { "+" } else { "" }
        Write-Host ("  #{0,-3} {1,-45} pendientes: {2,-4} items: {3}" -f `
                    $r.Num, $r.Titulo, "$($r.Pendientes)$sfx", "$($r.Items)$sfx") -ForegroundColor $color
        Write-Host ("        {0}" -f $r.Url) -ForegroundColor DarkCyan
    }
    if (@($rows | Where-Object { $_.Trunc }).Count -gt 0) {
        Write-Host ""
        Write-Host "TRUNCADO: los boards marcados con '+' tienen mas items de los que pude leer - sus cuentas son un minimo, no un total." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Siguiente paso: /board work para ver los pendientes de un board." -ForegroundColor Cyan
    exit 0
}

if ($ProjectNum -le 0) {
    throw "Usa -ListBoards, o -ProjectNum <n> (opcionalmente con -Start <issueNum> o -Parallel <nums>)."
}

if ($Start -gt 0 -and $Parallel.Count -gt 0) {
    throw "-Start y -Parallel son mutuamente exclusivos: usa uno u otro."
}

$boardUrl = Get-BoardUrl $ProjectNum

# ==============================================================================
# MODE 2: -ProjectNum  -> pending items of one board
# ==============================================================================
if ($Start -le 0 -and $ToReview -le 0 -and $Parallel.Count -eq 0 -and $groupQueue.Count -eq 0) {
    Write-Host "=== Pendientes del board #$ProjectNum de $Owner ===" -ForegroundColor Cyan
    Write-Host ""

    # Guard: if a foreign checkout moved this session off its work branch, say so up front.
    Show-BranchDrift

    $statusOpts = Get-StatusOptionNames $ProjectNum
    Show-StatusSchemaWarning $statusOpts $ProjectNum

    # Fails closed TWICE over. A read failure THROWS rather than yielding an empty list the script
    # would report as "Sin pendientes" (#278/#314) - and a read that hit the cap is flagged, because
    # `gh project item-list` returns items OLDEST-FIRST: on a mature board the cap fills with Done
    # work and the Backlog falls off the end. At --limit 200 against a 291-item board this printed a
    # confident "Sin pendientes" over 37 open Backlog items (#484).
    $read    = Get-BoardItems -Number $ProjectNum -Owner $Owner `
                              -What "listar los items del board #$ProjectNum"
    $items   = $read.Items
    $truncWarn = Get-BoardTruncationWarning $read
    $pending = @($items | Where-Object { Test-Pending $_ })

    if ($pending.Count -eq 0) {
        # "No pending" is only honest when every Status on the board is one this tool
        # understands. If ANY item sits in a vocabulary we cannot read, 0 matches means
        # "I cannot tell", not "the board is clean" - say that instead of the green
        # all-clear the script used to print over dozens of open issues (#278).
        # A truncated read means the same thing for a different reason, and outranks both:
        # zero matches inside a partial list is no evidence of zero matches on the board.
        $unknown = Get-UnknownStatusValues $items
        if ($truncWarn) {
            Write-Host $truncWarn -ForegroundColor Yellow
            Write-Host "No hay pendientes ENTRE LOS $($read.Read) items que lei - no afirmo que el board este limpio." -ForegroundColor Yellow
        } elseif ($unknown.Count -gt 0) {
            Write-Host "No puedo saber que hay pendiente: 0 items en Backlog, pero el board usa estados que no reconozco ($($unknown -join ', '))." -ForegroundColor Yellow
            Write-Host "No afirmo que no haya pendientes - revisa el board, o estandarizalo con /board field apply en --migrate." -ForegroundColor DarkGray
        } else {
            Write-Host "Sin pendientes. Todo el board esta en progreso o terminado." -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit 0
    }

    # A truncated read still lists what it found - but the list is a FLOOR, and saying so before it
    # matters more than after: the user picks an issue off the top of this list.
    if ($truncWarn) {
        Write-Host $truncWarn -ForegroundColor Yellow
        Write-Host "Los pendientes de abajo son los que alcance a ver; pueden faltar." -ForegroundColor Yellow
        Write-Host ""
    }

    # Sort: priority name ascending (P0 < P1 < P2), empty priority last
    $pending = $pending | Sort-Object -Property @{Expression={ if ($_.priority) { $_.priority } else { "zz" } }}

    foreach ($p in $pending) {
        $prio = if ($p.priority) { $p.priority } else { "(sin prio)" }
        $size = if ($p.size)     { $p.size }     else { "-" }
        $type = if ($p.type)     { $p.type }     else { "-" }
        if ($p.content.type -eq "DraftIssue") {
            Write-Host ("  [draft]  {0}" -f $p.title) -ForegroundColor DarkYellow
            Write-Host  "           (nota draft - conviertela a issue real con /board fill antes de trabajarla)" -ForegroundColor DarkGray
        } elseif (@($p.labels) -contains "blocked") {
            Write-Host ("  #{0,-4} [BLOCKED] {1}" -f $p.content.number, $p.title) -ForegroundColor Red
            Write-Host  "        bloqueado por una dependencia - no se puede empezar (quita el label 'blocked' al desbloquearse)" -ForegroundColor DarkGray
        } else {
            $repo = $p.content.repository
            Write-Host ("  #{0,-4} {1}" -f $p.content.number, $p.title) -ForegroundColor Yellow
            Write-Host ("        {0} | Size {1} | {2} | {3}" -f $prio, $size, $type, $repo) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    # "Total" is an exact claim, and a capped read cannot make one - the warning above says the
    # list may be short, so the number that closes it must agree with the warning, not contradict it.
    Write-Host ("Total: {0}{1} pendiente(s)." -f $pending.Count, $(if ($truncWarn) { '+ (vistos; la lectura se corto)' } else { '' })) -ForegroundColor Yellow

    # Multi-session: show what other LIVE local sessions are working right now.
    # NOT named $sessions: at SCRIPT scope that is the [switch]$Sessions parameter
    # (PowerShell variable names are case-insensitive), so assigning an array to it
    # threw "cannot convert Object[] to SwitchParameter" and killed the listing right
    # after printing it - the board link and next step never rendered. The two other
    # Read-SessionRegistry call sites are inside functions, where the local scope
    # shadows the parameter, which is why only this one broke.
    $liveSessions = @(Read-SessionRegistry)
    if ($liveSessions.Count -gt 0) {
        Write-Host ""
        Write-Host "Sesiones activas en esta maquina:" -ForegroundColor Cyan
        foreach ($s in $liveSessions) {
            Write-Host ("  #{0}  rama {1}  (PID {2} vivo, desde {3}) en {4}" -f $s.issue, $s.branch, $s.sessionPid, $s.started, $s.workPath) -ForegroundColor DarkCyan
        }
    }

    # Grouped PRs (#662). The per-PR cycle - review gate, second-opinion round, merge
    # confirmation - is paid once per PR, so the moment to say what N separate PRs will cost
    # is HERE, while the user is still choosing, not after the first one is already open.
    $cfgRead = Read-BoardConfig -Path (Get-BoardConfigPath)
    if (-not $cfgRead.ok) {
        Write-Host ""
        Write-Host "No pude leer la preferencia de este repo sobre agrupar PRs ($($cfgRead.error))." -ForegroundColor Yellow
        Write-Host "Sigo con el criterio por defecto; no asumo que no haya preferencia." -ForegroundColor DarkGray
    }
    $posture = Resolve-GroupingPosture $cfgRead.config
    # Not being in a clone is a SUPPORTED way to run this listing - the contract's step 1 says so
    # ("outside a repo, skip the scope question"). Get-RepoFromOrigin throws there, so it is
    # guarded exactly like the CloseLoop call site: no repo just means no file evidence and no
    # "is this group mine" comparison, which the helpers already handle. Letting it throw would
    # kill the listing AFTER printing it, over a feature that is only ever an offer.
    $hereRepo = try { Get-RepoFromOrigin } catch { '' }
    $groups  = @(Get-GroupingSuggestions -Pending $pending -RepoFiles (Get-RepoTrackedFiles) -CurrentRepo $hereRepo)
    Show-GroupingOffer -Suggestions $groups -Posture $posture -CurrentRepo $hereRepo

    Write-Host ""
    $startable = if ($posture -ne 'never') { Select-StartableGroup -Suggestions $groups -CurrentRepo $hereRepo } else { $null }
    if ($startable) {
        $first = ($startable.issues) -join ','
        Write-Host "Siguiente paso: /board work -StartGroup $first (un PR), o -Start <issueNum> para uno suelto." -ForegroundColor Cyan
    } else {
        if ($posture -ne 'never' -and $groups.Count -gt 0 -and $hereRepo) {
            # There ARE groups, just none in this folder. Offering the biggest one anyway would
            # start issues here whose PR cannot close them.
            $otros = (@($groups | ForEach-Object { $_.repo } | Sort-Object -Unique) -join ', ')
            Write-Host "Los lotes de arriba son de otros repos ($otros): hay que abrirlos desde su propia copia." -ForegroundColor DarkYellow
        }
        Write-Host "Siguiente paso: /board work -Start <issueNum> (o -Parallel <n1,n2,...>)." -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ==============================================================================
# MODE 4: -ProjectNum -ToReview <issueNum>  -> move item to the "In Review" column
# The work flow calls this after opening the PR: the change is now in review /
# testing while the gate runs. Merge later moves it to Done (close->Done + fill).
# ==============================================================================
if ($ToReview -gt 0) {
    # -Graphql fails closed on exit OR errors[], so a read failure throws here instead of a null
    # id mislabelled "board not found" - this read drives the In Review write below (#314).
    $toReviewQuery = '
query($owner:String!, $num:Int!) {
  user(login:$owner) {
    projectV2(number:$num) {
      id
      fields(first:30) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } }
    }
  }
}'
    $projData = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$toReviewQuery",'-F',"owner=$Owner",'-F',"num=$ProjectNum") `
                          -What "resolver el board #$ProjectNum de $Owner" -Graphql

    $projectId  = $projData.data.user.projectV2.id
    if (-not $projectId) { throw "Board #$ProjectNum no encontrado para $Owner." }
    $statusNode = $projData.data.user.projectV2.fields.nodes | Where-Object { $_.name -eq "Status" }
    # Vocabulary-aware, like every other Status write: a board whose column is called
    # 'Review' is understood instead of being refused (Codex review, PR #279).
    $reviewId   = Resolve-StatusOptionId $statusNode "In Review"
    if (-not $reviewId) {
        throw "El board #$ProjectNum no tiene la opcion 'In Review' en Status. Agregala (/board field apply en) antes de usar -ToReview."
    }

    # Find the item by reusing Get-BoardItem, which paginates the whole board (#246)
    # and retries for eventual consistency - no separate capped query here.
    $item = Get-BoardItem $projectId $ToReview
    if (-not $item) { throw "Issue #$ToReview no esta en el board #$ProjectNum." }

    if ($DryRun) {
        Write-Host "DRY-RUN: #$ToReview '$($item.content.title)' -> Status In Review (no ejecutado)." -ForegroundColor Gray
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit 0
    }

    # -Graphql throws on exit OR errors[]: never print "OK -> In Review" for a move that silently
    # no-op'd (PR is open, the gate expects In Review, but the item stayed put) (#314).
    $toReviewMutation = '
mutation($proj:ID!,$item:ID!,$field:ID!,$opt:String!) {
  updateProjectV2ItemFieldValue(input:{
    projectId:$proj, itemId:$item, fieldId:$field,
    value:{singleSelectOptionId:$opt}
  }) { projectV2Item { id } }
}'
    $null = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$toReviewMutation",'-f',"proj=$projectId",'-f',"item=$($item.id)",'-f',"field=$($statusNode.id)",'-f',"opt=$reviewId") `
                      -What "mover #$ToReview a In Review" -Graphql
    Write-Host "OK  #$ToReview '$($item.content.title)' -> Status In Review (en review/testing)." -ForegroundColor Green
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ==============================================================================
# MODE 5: -ProjectNum -Parallel <issueNums>  -> batch-start, one worktree each
# ==============================================================================
if ($Parallel.Count -gt 0) {
    # Normalize to the batch queue (drop <=0, de-dup, keep order).
    $queue = @(Get-ParallelQueue $Parallel)
    if ($queue.Count -eq 0) { throw "-Parallel no recibio numeros de issue validos." }

    Write-Host "=== Parallel batch-start (board #$ProjectNum de $Owner) ===" -ForegroundColor Cyan
    Write-Host ("  Issues: {0}" -f ($queue -join ', ')) -ForegroundColor DarkGray
    if ($DryRun) { Write-Host "  Modo DRY-RUN - planifica sin mutar el board ni tocar git." -ForegroundColor Gray }
    Write-Host ""

    $ctx = Resolve-BoardStatus $Owner $ProjectNum

    # The base is resolved per issue inside New-IssueWorkspace, which shares one code path
    # with single -Start (#294). This path used to hardcode origin/main, which silently
    # based every worktree on the wrong branch in a repo whose default is master - and it
    # ignored -BaseCurrent entirely, honouring a base the caller had not asked for.
    $results = @()
    foreach ($n in $queue) {
        Write-Host ("--- #{0} ---" -f $n) -ForegroundColor Cyan
        $r = Invoke-BatchIssueStart -IssueNum $n -Ctx $ctx -Owner $Owner `
                                    -Base $Base -BaseCurrent:$BaseCurrent -DryRun:$DryRun `
                                    -IgnoreBlocked:$IgnoreBlocked -TakeOver:$TakeOver
        $results += $r
        Write-Host ""
    }

    # -- Summary ---------------------------------------------------------------
    Write-Host "===== RESUMEN PARALELO =====" -ForegroundColor Cyan
    $started = @($results | Where-Object { $_.started })
    $planned = @($results | Where-Object { $_.dryRun -and -not $_.skipped })
    $skipped = @($results | Where-Object { $_.skipped })
    foreach ($r in $results) {
        if ($r.skipped) {
            Write-Host ("  #{0,-4} SKIP  {1}" -f $r.issue, $r.skipped) -ForegroundColor Red
        } elseif ($r.dryRun) {
            Write-Host ("  #{0,-4} plan  -> rama {1}" -f $r.issue, $r.branch) -ForegroundColor Gray
        } else {
            Write-Host ("  #{0,-4} OK    -> {1}" -f $r.issue, $r.workPath) -ForegroundColor Green
        }
    }
    Write-Host ""

    if ($DryRun) {
        Write-Host ("DRY-RUN: {0} se iniciarian, {1} se saltarian. Ningun cambio hecho." -f $planned.Count, $skipped.Count) -ForegroundColor Gray
    } else {
        Write-Host ("Iniciados: {0} / {1}. Worktrees listos, uno por issue." -f $started.Count, $queue.Count) -ForegroundColor Yellow
        if ($started.Count -gt 0 -and -not $Launch -and -not $Fleet) {
            Write-Host ""
            Write-Host "Cada worktree tiene su rama y su claim. Trabaja cada issue en su carpeta:" -ForegroundColor Cyan
            foreach ($r in $started) {
                if ($r.workPath) { Write-Host ("  cd `"{0}`"   # #{1}" -f $r.workPath, $r.issue) -ForegroundColor DarkCyan }
            }
            Write-Host ""
            Write-Host "Al terminar cada uno: PR con 'Closes #<num>' + el gate de review obligatorio." -ForegroundColor DarkGray
            Write-Host "Agrega -Launch para abrir una sesion Claude por worktree automaticamente." -ForegroundColor DarkGray
        }
    }

    # All -Launch/-Fleet sessions arm the brake by default (#598). -AllowMerge is the
    # explicit opt-in for autonomous merging; an expert contract that allows merging
    # is honoured via an explicit -StopAtPR:$false. See Resolve-LaunchBrake for the logic.
    $launchBrake = Resolve-LaunchBrake -AllowMerge ([bool]$AllowMerge) `
        -StopAtPRBound $PSBoundParameters.ContainsKey('StopAtPR') `
        -StopAtPR ([bool]$StopAtPR)

    # -- Launch: one visible session per worktree. -Fleet probes CLIs and picks one
    # per issue (fallback claude); plain -Launch keeps the shipped claude-only path.
    # -Fleet TAKES OVER the launch (elseif), so the two never both spawn in one run.
    if ($Fleet) {
        Write-Host ""
        Write-Host "----- FLEET (una CLI por issue, fallback claude) -----" -ForegroundColor Cyan
        # Availability across every adapter. A not-installed CLI is offered for install
        # (only in a real run); if still unavailable it just stays that way (fallback).
        $availability = @{}
        foreach ($adapter in Get-CliAdapters) {
            $res = Test-CliAvailability -Adapter $adapter
            if ($res.Status -eq 'not-installed' -and -not $DryRun) {
                if (Install-CliOnApproval $adapter) { $res = Test-CliAvailability -Adapter $adapter }
            }
            $availability[$adapter.Name] = $res.Status
        }

        if ($DryRun) {
            # No prompt / install / spawn under -DryRun: just show the probe table and
            # the default plan (every started issue -> claude; the real picker runs live).
            Write-Host "  CLIs disponibles (probe):" -ForegroundColor DarkGray
            Show-CliAvailability $availability | Out-Null
            $defaultMap = @{}
            foreach ($r in $planned) { $defaultMap[$r.issue] = 'claude' }
            $dryPlan = Build-FleetPlan -Started $planned -CliMap $defaultMap
            Write-Host "  Plan por defecto (el picker por-issue corre en la ejecucion real):" -ForegroundColor DarkGray
            foreach ($e in $dryPlan) { Write-Host ("    #{0,-4} -> {1}" -f $e.issue, $e.cli) -ForegroundColor Gray }
        } else {
            # Auth preflight: a claude fallback session is headless, so it needs an explicit
            # user-env credential (the Desktop host's OAuth is not shared with children).
            $oauthPresent  = [bool][System.Environment]::GetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'User')
            $ClaudeAuthVar = Resolve-ClaudeAuthVar $PSBoundParameters.ContainsKey('ClaudeAuthVar') $ClaudeAuthVar $oauthPresent
            if ($ClaudeAuthVar -eq 'CLAUDE_CODE_OAUTH_TOKEN') {
                Write-Host "  Auth: usando CLAUDE_CODE_OAUTH_TOKEN (suscripcion)." -ForegroundColor DarkGray
            }
            $claudeAuth = [System.Environment]::GetEnvironmentVariable($ClaudeAuthVar, "User")
            if (-not $claudeAuth) {
                Write-Host ""
                Write-Host ("  AUTH REQUERIDA - las sesiones headless necesitan '{0}' en tus variables de usuario." -f $ClaudeAuthVar) -ForegroundColor Red
                Write-Host "  (El login del Desktop NO se comparte con procesos hijos, darian 401.)" -ForegroundColor DarkYellow
                Write-Host "  Opcion A (API key): setx ANTHROPIC_API_KEY <tu-api-key>" -ForegroundColor Gray
                Write-Host "  Opcion B (suscripcion): claude setup-token ; setx CLAUDE_CODE_OAUTH_TOKEN <token> ; -ClaudeAuthVar CLAUDE_CODE_OAUTH_TOKEN" -ForegroundColor Gray
                Write-Host "  Reinicia la terminal y re-lanza con -Fleet (los worktrees ya estan listos; monitorea con -Sessions)." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Board: $boardUrl" -ForegroundColor Cyan
                exit 0
            }
            # Pick a CLI per issue (interactive), then pair each worktree with its choice.
            $issueNums = @($started | ForEach-Object { $_.issue })
            $map       = Select-CliPerIssue -Issues $issueNums -Availability $availability
            $fleetPlan = @(Build-FleetPlan -Started $started -CliMap $map | Where-Object { $_.workPath })
            # One runId ties every session of this dispatch together for the reaper.
            $runId = New-FleetRunId
            # Seed the runtime backoff: a CLI that already probed out of quota is skipped for
            # the rest of the run (its issue still launches, on the claude fallback).
            $noQuota = @{}
            foreach ($k in @($availability.Keys)) { if ($availability[$k] -eq 'no-quota') { $noQuota[$k] = $true } }
            # The spawn+register step, wrapped as the governor's launch hook. The governor
            # already applied no-quota backoff; Resolve-LaunchCli re-checks availability at
            # spawn time (defense in depth) so an unavailable CLI never actually launches.
            $launchHook = {
                param($entry, $cli)
                $actualCli = Resolve-LaunchCli -Chosen $cli -Availability $availability
                $marker    = New-FleetSessionMarker $entry.issue $runId
                $spawn = Start-WorktreeSession -IssueNum $entry.issue -Repo $entry.repo -Branch $entry.branch `
                                               -WorkPath $entry.workPath -ClaudeAuthVar $ClaudeAuthVar -Cli $actualCli -FleetSession $marker `
                                               -StopAtPR:$launchBrake -BriefFile $BriefFile -Irreversible $Irreversible -EndToEnd:$EndToEnd -SessionBudgetMinutes $BudgetMinutes
                $via = if ($spawn.usesWt) { "wt" } else { "pwsh" }
                if ($spawn.process -and -not $spawn.usesWt) {
                    Write-SessionRegistryEntry -IssueNum $entry.issue -SessionPid $spawn.process.Id -Via $via -Cli $actualCli -FleetSession $marker
                } else {
                    Write-SessionRegistryEntry -IssueNum $entry.issue -Via $via -Cli $actualCli -FleetSession $marker
                }
                $actualCli
            }.GetNewClosure()
            # Governor: pace launches in waves sized to machine capacity, instead of firing
            # the whole batch at once (Invoke-FleetDispatch -> Get-DispatchPlan/Wait-FleetSlot).
            # -MaxConcurrent (0 = capacity-only) caps how many run at once.
            $dispatched = @(Invoke-FleetDispatch -Queue $fleetPlan -NoQuotaClis $noQuota -LaunchSession $launchHook -MaxConcurrent $MaxConcurrent)
            Write-Host ""
            $fleetBrakeMsg = if ($launchBrake) { "freno ARMADO (sesiones paran en el PR listo)." } else { "ATENCION: freno desarmado con -AllowMerge." }
            Write-Host ("Fleet lanzada: {0} sesion(es) en oleadas por capacidad (fallback claude). {1}" -f $dispatched.Count, $fleetBrakeMsg) -ForegroundColor Yellow
        }
    } elseif ($Launch) {
        Write-Host ""
        # Auto-prefer the subscription OAuth token when the caller did not pick an
        # auth var explicitly (see Resolve-ClaudeAuthVar).
        $oauthPresent  = [bool][System.Environment]::GetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'User')
        $ClaudeAuthVar = Resolve-ClaudeAuthVar $PSBoundParameters.ContainsKey('ClaudeAuthVar') $ClaudeAuthVar $oauthPresent
        if ($ClaudeAuthVar -eq 'CLAUDE_CODE_OAUTH_TOKEN') {
            Write-Host "  Auth: usando CLAUDE_CODE_OAUTH_TOKEN (suscripcion)." -ForegroundColor DarkGray
        }
        if ($DryRun) {
            Write-Host "----- LAUNCH (preview, -DryRun no lanza nada) -----" -ForegroundColor Cyan
            $runId = New-FleetRunId
            foreach ($r in $planned) {
                # Use the SAME path logic as real creation so the preview matches (see
                # New-IssueWorktree / Get-IssueWorktreePath - the grouped-worktree layout).
                $previewPath = Get-IssueWorktreePath $r.repo $r.issue (Split-Path (Get-Location) -Parent)
                $marker = New-FleetSessionMarker $r.issue $runId
                Start-WorktreeSession -IssueNum $r.issue -Repo $r.repo -Branch $r.branch -WorkPath $previewPath -ClaudeAuthVar $ClaudeAuthVar -FleetSession $marker -StopAtPR:$launchBrake -BriefFile $BriefFile -Preview | Out-Null
            }
        } else {
            Write-Host "----- LANZANDO SESIONES CLAUDE -----" -ForegroundColor Cyan
            # Preflight: unattended headless sessions need an explicit credential in
            # the Windows USER env (the Desktop host's OAuth is not shared with child
            # processes). Without it every tab would 401 silently - warn and don't spawn.
            $claudeAuth = [System.Environment]::GetEnvironmentVariable($ClaudeAuthVar, "User")
            if (-not $claudeAuth) {
                Write-Host ""
                Write-Host ("  AUTH REQUERIDA - las sesiones headless necesitan '{0}' en tus variables de usuario." -f $ClaudeAuthVar) -ForegroundColor Red
                Write-Host "  (El login del Desktop NO se comparte con procesos hijos, darian 401.)" -ForegroundColor DarkYellow
                Write-Host "  Opcion A (API key, facturacion por consumo a tu cuenta de consola):" -ForegroundColor Yellow
                Write-Host "    setx ANTHROPIC_API_KEY <tu-api-key>" -ForegroundColor Gray
                Write-Host "  Opcion B (suscripcion Claude): genera un token y apunta el launcher a el:" -ForegroundColor Yellow
                Write-Host "    claude setup-token   ; setx CLAUDE_CODE_OAUTH_TOKEN <token>   ; luego -ClaudeAuthVar CLAUDE_CODE_OAUTH_TOKEN" -ForegroundColor Gray
                Write-Host "  Reinicia la terminal y re-lanza con -Launch (los worktrees ya estan listos; monitorea con -Sessions)." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Board: $boardUrl" -ForegroundColor Cyan
                exit 0
            }
            $launched = 0
            # One runId ties every session of this launch together for the reaper.
            $runId = New-FleetRunId
            foreach ($r in $started) {
                if ($r.workPath) {
                    $marker = New-FleetSessionMarker $r.issue $runId
                    $spawn = Start-WorktreeSession -IssueNum $r.issue -Repo $r.repo -Branch $r.branch -WorkPath $r.workPath -ClaudeAuthVar $ClaudeAuthVar -FleetSession $marker -StopAtPR:$launchBrake -BriefFile $BriefFile -Irreversible $Irreversible -EndToEnd:$EndToEnd -SessionBudgetMinutes $BudgetMinutes
                    $launched++
                    # Track the spawned session's own PID (pwsh window is reliable; a wt
                    # launcher forks and exits, so keep the host PID there).
                    $via = if ($spawn.usesWt) { "wt" } else { "pwsh" }
                    if ($spawn.process -and -not $spawn.usesWt) {
                        Write-SessionRegistryEntry -IssueNum $r.issue -SessionPid $spawn.process.Id -Via $via -FleetSession $marker
                    } else {
                        Write-SessionRegistryEntry -IssueNum $r.issue -Via $via -FleetSession $marker
                    }
                }
            }
            Write-Host ""
            $brakeMsg = if ($launchBrake) { "el freno esta ARMADO: las sesiones paran en el PR listo (no mergean solas)." } else { "ATENCION: freno desarmado con -AllowMerge - las sesiones PUEDEN mergear autonomamente." }
            Write-Host ("Lanzadas: {0} sesion(es). {1}" -f $launched, $brakeMsg) -ForegroundColor Yellow
        }
    }

    # -Watch: after launching, block here polling until every session finishes, then
    # (with -AutoClean) tear down its worktree/branch/registry entry (issue #135). Skipped
    # under -DryRun (nothing was spawned) and when nothing was launched.
    if ($Watch -and -not $DryRun -and ($Launch -or $Fleet)) {
        Write-Host ""
        Write-Host ("=== Watch (poll {0}s, timeout {1}s{2}) ===" -f $WatchPollSec, $WatchTimeoutSec, $(if ($AutoClean) { ', auto-clean' } else { '' })) -ForegroundColor Cyan
        Invoke-SessionWatch -PollSec $WatchPollSec -TimeoutSec $WatchTimeoutSec -AutoClean:$AutoClean -ForceDeleteBranch:$ForceDeleteBranch -ForceRemoveWorktree:$ForceRemoveWorktree | Out-Null
    }

    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ==============================================================================
# MODE 3b: -ProjectNum -StartGroup <n1,n2,...>  -> ONE shared branch for several small,
# sequential sub-issues of the same epic (#633), so they close through ONE PR/gate/merge
# instead of a full start->PR->gate->merge cycle per issue.
#
# The FIRST issue in the group is the leader: it gets the branch/worktree exactly like a
# normal -Start (board mechanics + New-IssueWorkspace). The rest only get the board mechanics
# (Status -> In Progress, assignee, [abios-claim] comment) via the same Invoke-IssueStart,
# just without -MakeBranch - then a session-registry row is added for each, pointing at the
# leader's branch/workPath, so /board watch and cleanup see the whole group as one session.
# ==============================================================================
if ($groupQueue.Count -gt 0) {
    Write-Host "=== Empezando lote de issues $($groupQueue -join ', ') (board #$ProjectNum de $Owner) ===" -ForegroundColor Cyan
    Write-Host ""

    $ctx = Resolve-BoardStatus $Owner $ProjectNum
    $lead = Invoke-IssueStart -IssueNum $groupQueue[0] -Ctx $ctx -Owner $Owner -MakeBranch:$Branch `
                              -Base $Base -BaseCurrent:$BaseCurrent `
                              -DryRunStart:$DryRun -IgnoreBlocked:$IgnoreBlocked -TakeOver:$TakeOver
    if ($lead.skipped) {
        Write-Host ""
        Write-Host "Lote ABORTADO: el issue lider #$($groupQueue[0]) no pudo empezar - ningun issue del lote fue tocado." -ForegroundColor Red
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit 1
    }

    $started = @($lead)
    foreach ($n in ($groupQueue | Select-Object -Skip 1)) {
        $r = Invoke-IssueStart -IssueNum $n -Ctx $ctx -Owner $Owner `
                               -Base $Base -BaseCurrent:$BaseCurrent `
                               -DryRunStart:$DryRun -IgnoreBlocked:$IgnoreBlocked -TakeOver:$TakeOver
        if ($r.skipped) {
            Write-Host "  (#$n queda fuera del lote - la rama compartida sigue siendo valida para el resto)" -ForegroundColor DarkYellow
            continue
        }
        if (-not $DryRun -and $lead.workPath) {
            Write-SessionRegistryEntry -IssueNum $n -Branch $lead.branch -WorkPath $lead.workPath -Repo $lead.repo
        }
        $started += $r
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "Modo DRY-RUN - ningun cambio ejecutado." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Board: $boardUrl" -ForegroundColor Cyan
        exit 0
    }

    $startedNums = ($started | ForEach-Object { $_.issue }) -join ','
    Write-Host ""
    Write-Host ("Lote listo: {0} de {1} issue(s) en UNA sola rama ({2})." -f $started.Count, $groupQueue.Count, $lead.branch) -ForegroundColor Green
    Write-Host "AL TERMINAR (un solo PR para todo el lote): abre el PR citando los issues $startedNums" -ForegroundColor Yellow
    Write-Host "(un solo review gate + un solo merge cierran los $($started.Count) issues a la vez)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

# ==============================================================================
# MODE 3: -ProjectNum -Start <issueNum>  -> move to In Progress + assign + context
# ==============================================================================
Write-Host "=== Empezando issue #$Start (board #$ProjectNum de $Owner) ===" -ForegroundColor Cyan
Write-Host ""

$ctx = Resolve-BoardStatus $Owner $ProjectNum
$r = Invoke-IssueStart -IssueNum $Start -Ctx $ctx -Owner $Owner -MakeBranch:$Branch `
                       -Base $Base -BaseCurrent:$BaseCurrent `
                       -DryRunStart:$DryRun -IgnoreBlocked:$IgnoreBlocked -TakeOver:$TakeOver

if ($r.skipped) {
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 1
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Modo DRY-RUN - ningun cambio ejecutado." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Board: $boardUrl" -ForegroundColor Cyan
    exit 0
}

Write-Host ""
Write-IssueContext $Start $r.repo
Write-Host ""
Write-Host "Issue #$Start listo para trabajar (In Progress, asignado a $Owner)." -ForegroundColor Green
Write-Host "AL TERMINAR: abre el PR citando 'Closes #$Start' con la cuenta correcta - NO commit directo a main." -ForegroundColor Yellow
Write-Host "(asi GitHub llena solo la columna 'Linked pull requests' del board)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Board: $boardUrl" -ForegroundColor Cyan

