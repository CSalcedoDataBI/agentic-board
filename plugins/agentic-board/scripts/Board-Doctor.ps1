<#
.SYNOPSIS
    Inventory and classify every local branch and worktree from GIT REALITY - not from
    the session registry. Read-only by default; `-Fix` cleans up, confirming per branch.

.DESCRIPTION
    The rest of the lifecycle is anchored to `.agentic-board/sessions.json`, which is a
    PROCESS registry, not a git-ref inventory (#274). Cleanup only ever happens as a side
    effect of watching a LIVE session complete (`Board-Work.ps1 -Sessions -Watch -AutoClean`),
    and the registry drops dead-PID entries from every read - so the moment an agent crashes,
    its branch and worktree vanish from every view instead of being flagged. Anything created
    outside a live registered session is unreachable by every cleanup path: branches whose
    agent died, hand-made branches (CONTRIBUTING.md invites them), branches predating the
    registry, worktrees orphaned by a failed remove.

    This command is that missing audit path. It walks `git for-each-ref`, `git worktree list`
    and `gh pr list`, and classifies each branch. The session registry is read ONLY to mark a
    branch as belonging to a live session, which PROTECTS it from `-Fix`; it never decides
    what exists and never invents a class of its own.

    WHY NOT `git branch --merged main`: this repo squash-merges (`Board-Merge.ps1 -Method
    squash`), which rewrites the commits, so a perfectly merged branch is never an ancestor of
    main. Measured here: 62 local branches, of which `--merged main` reports 4. A doctor built
    on that signal would flag ~51 safely-merged branches as needing attention and be useless -
    the exact trap #273 hit (see PR #275). The merge verdict therefore comes from the PR:
    MERGED **and** `headRefOid` == the local branch tip. That is not a re-implementation -
    it is `Get-SessionCompletion` (Board-Work.ps1), dot-sourced here so the two verdicts can
    never drift apart.

    NOT AN "ORPHAN": that word is already taken in this codebase and never means a branch -
    `Find-FleetOrphans` means escaped OS processes and knowledge-ops means unused registry
    domains. Hence "doctor" / "stale" / "ghost".

    DELIBERATE LEFTOVERS ARE NOT ALARMS: since #273/#276 the teardown deliberately KEEPS an
    unmerged branch (`git branch -d` refusing) and a worktree holding uncommitted files, and
    says it leaves them "for the audit path". This is that path, so those states are reported
    as expected keeps, not failures.

.PARAMETER Repo
    owner/name. Defaults to the `origin` remote of the current repo.

.PARAMETER StaleDays
    A branch with no PR whose tip is older than this many days is `stale`. Default 30.

.PARAMETER Prefix
    Only audit branches matching this wildcard. Default `*` (every local branch). The
    default branch and any branch given in -Protect are always excluded.

.PARAMETER Protect
    Branch names that are never classified or touched. Defaults to main/master/develop plus
    the remote's actual default branch.

.PARAMETER Fix
    Opt in to the destructive pass. Confirms EVERY branch individually (y/n/a/q) before
    touching it - `a` = yes-to-all within the current class only. Without it nothing is
    written. Unmerged branches always require an explicit per-branch confirmation: there is
    no flag that force-deletes them in bulk.

.PARAMETER Auto
    With -Fix: skip the confirmation for the `merged` class ONLY - the one that is PROVEN safe
    (a MERGED PR whose headRefOid is the branch tip). For the flow "run read-only, read the
    list, decide yes" and for automation, mirroring Board-Fill.ps1 -Auto. It does NOT touch
    `stale` or `closed-unmerged`: unmerged work is never bulk-deleted, with or without this
    flag, and those walks are skipped entirely under -Auto since they cannot prompt. The dirty
    worktree and current-worktree guards still apply.

.PARAMETER DryRun
    With -Fix: print exactly what would be deleted/pruned and exit without doing it.

.PARAMETER Json
    Emit the classified inventory as JSON instead of the human table (for scripting/CI).

.PARAMETER PrLimit
    How many PRs to fetch (default 1000). If the repo has more, the script REFUSES to run
    rather than classify against a truncated list - raise this above the repo's PR count.

.EXAMPLE
    .\Board-Doctor.ps1                      # read-only audit of this repo
    .\Board-Doctor.ps1 -StaleDays 14        # stricter staleness threshold
    .\Board-Doctor.ps1 -Fix -DryRun         # show the cleanup plan, change nothing
    .\Board-Doctor.ps1 -Fix                 # clean up, confirming branch by branch
#>
[CmdletBinding()]
param(
    [string]$Repo      = "",
    [int]   $StaleDays = 30,
    [string]$Prefix    = "*",
    [string[]]$Protect = @(),
    [switch]$Fix,
    [switch]$Auto,
    [switch]$DryRun,
    [switch]$Json,
    [int]   $PrLimit   = 1000,
    [string]$TokenVar  = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# The single resolver for the internal state dir (new name + migration + fallback).
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')

# The single resolver for owner/name from this clone's origin (#281, #392). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# Reuse (do not re-implement) the merge verdict and the live-session view. Board-Work.ps1
# exposes a documented dot-source guard for exactly this: it returns before its main entry,
# so no token is needed and nothing is executed. `Get-SessionCompletion` is the pure,
# unit-tested answer to "is this branch REALLY merged?" - the same question the doctor asks
# (#274), and `Read-SessionRegistry` is the live-session view used here only to PROTECT.
#
# DANGER, and the reason for the restore below: dot-sourcing a script runs its `param()` block
# in OUR scope, so every parameter name we share with Board-Work.ps1 (-Repo, -DryRun, -TokenVar)
# is silently reset to ITS default. That is not cosmetic: it clobbered -DryRun to $false, so
# `-Fix -DryRun` announced a dry run and then really deleted branches. $PSBoundParameters holds
# exactly what the caller passed - i.e. exactly what can be clobbered - so replaying it
# afterwards restores our binding precisely, and keeps covering any parameter added later.
$script:PrevDotSource = $env:ABIOS_BOARDWORK_DOTSOURCE
$env:ABIOS_BOARDWORK_DOTSOURCE = '1'
try   { . (Join-Path $PSScriptRoot 'Board-Work.ps1') }
finally {
    $env:ABIOS_BOARDWORK_DOTSOURCE = $script:PrevDotSource
    foreach ($k in $PSBoundParameters.Keys) { Set-Variable -Name $k -Value $PSBoundParameters[$k] -Scope Local }
}

# ------------------------------------------------------------------ pure helpers
#
# Get-WorktreeRecords and Test-WorktreeStillRegistered used to live HERE, and moved to
# Board-Work.ps1 (#289) - the dot-source above brings them in, exactly like Get-SessionCompletion.
# They moved because the session teardown needs the same "did the removal take?" verdict, and the
# dependency only runs doctor -> work: Board-Work cannot dot-source us back without a cycle, and
# a second copy is the drift this file refuses everywhere else.

# Which PR speaks for THIS branch tip? Several PRs can share a reused branch name
# (-TakeOver reuses `issue-<n>-<slug>`), so "the newest one" is not trustworthy: an old
# MERGED PR would vouch for new work. Prefer the PR whose head IS our tip; fall back to the
# newest only for the non-matching case, where a MERGED state proves nothing anyway and the
# classifier treats it as such. Mirrors Get-SessionLiveStatus (Board-Work.ps1:1708). PURE.
function Select-BranchPr {
    param(
        [object[]]$Prs = @(),
        [string]$Tip = ''
    )
    $mine = @($Prs | Where-Object { $Tip -and $_.headRefOid -eq $Tip }) | Select-Object -First 1
    if ($mine) { return $mine }
    return (@($Prs | Sort-Object { [int]$_.number } -Descending) | Select-Object -First 1)
}

# Read a `git status --porcelain` result into clean|dirty|unknown. PURE -> unit-testable, which
# matters because this is the last thing standing between `worktree remove --force` and somebody's
# uncommitted files. FAIL CLOSED: a non-zero exit or a missing directory is 'unknown', never
# 'clean' (the #277 rule). Kept separate from the git call so the decision can be tested without
# a repo; the call site is responsible for passing --untracked-files=all.
function Get-WorktreeDirtyState {
    param(
        [int]$ExitCode = 0,
        [string[]]$StatusLines = @(),
        [bool]$PathExists = $true
    )
    if (-not $PathExists) { return 'unknown' }
    if ($ExitCode -ne 0)  { return 'unknown' }
    if ((@($StatusLines) -join "`n").Trim()) { return 'dirty' }
    return 'clean'
}

# Classify ONE branch. PURE -> unit-testable: every fact arrives as an argument.
#
# The merge verdict delegates to Get-SessionCompletion, so "merged" here means exactly what
# it means to the teardown: a MERGED PR whose headRefOid IS this tip. Ancestry is never
# consulted - see the -Description note on squash merges.
#
# $HasLiveSession comes from the registry and is used ONLY to protect (class `active`, and
# never auto-deletable). It cannot make a branch appear or disappear.
function Get-BranchClass {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Tip,
        [object[]]$Prs = @(),
        [datetime]$CommitDate = [datetime]::MinValue,
        [datetime]$Now = [datetime]::MinValue,
        [int]$StaleDays = 30,
        [bool]$HasLiveSession = $false,
        [string]$WorktreePath = '',
        [string]$Dirty = 'clean'     # clean | dirty | unknown (unknown = fail closed)
    )
    $pr = Select-BranchPr -Prs $Prs -Tip $Tip
    $prNum = if ($pr) { [int]$pr.number } else { 0 }
    $ageDays = if ($CommitDate -gt [datetime]::MinValue -and $Now -gt [datetime]::MinValue) {
        [math]::Floor(($Now - $CommitDate).TotalDays)
    } else { -1 }

    $mk = {
        param($class, $reason, $deletable)
        [pscustomobject]@{
            Branch = $Name; Class = $class; Reason = $reason; Pr = $prNum
            PrState = $(if ($pr) { $pr.state } else { '' })
            AgeDays = $ageDays; WorktreePath = $WorktreePath; Dirty = $Dirty
            HasLiveSession = $HasLiveSession
            # Deletable = eligible for the -Fix pass at all. It NEVER means "delete without
            # asking": -Fix confirms every branch. A live session is never deletable.
            Deletable = ($deletable -and -not $HasLiveSession)
        }
    }

    if ($pr) {
        # The one authoritative signal. IssueState/PidAlive are deliberately left at their
        # defaults so ONLY the merge branch of Get-SessionCompletion can fire: we want its
        # `merged` predicate, not its session-completion opinion.
        $verdict = Get-SessionCompletion -PrState $pr.state -PrHeadOid ([string]$pr.headRefOid) -BranchTip $Tip
        if ($verdict.merged) {
            return & $mk 'merged' "PR #$prNum mergeado (tip coincide)" $true
        }
        if ($pr.state -eq 'MERGED') {
            # Merged PR, but its head is NOT our tip: either commits landed on top after the
            # merge, or the name was reused by a later session. Either way the merge proves
            # nothing about THESE commits - surface it, never delete it.
            return & $mk 'merged-advanced' "PR #$prNum mergeado pero la rama tiene commits encima (el merge no prueba este tip)" $false
        }
        if ($pr.state -eq 'OPEN')   { return & $mk 'in-review' "PR #$prNum abierto" $false }
        if ($pr.state -eq 'CLOSED') { return & $mk 'closed-unmerged' "PR #$prNum cerrado sin mergear" $false }
    }

    if ($HasLiveSession) { return & $mk 'active' 'sesion viva trabajando esta rama' $false }
    if ($Dirty -eq 'dirty')   { return & $mk 'dirty' 'worktree con cambios sin commitear (conservado a proposito, #276)' $false }
    if ($Dirty -eq 'unknown') { return & $mk 'dirty' 'no pude comprobar si el worktree tiene cambios [git status fallo] - revisalo a mano' $false }
    if ($ageDays -ge 0 -and $ageDays -gt $StaleDays) {
        return & $mk 'stale' "sin PR y sin actividad hace $ageDays dias" $false
    }
    return & $mk 'working' 'sin PR todavia, reciente' $false
}

# Presentation order + labels. `merged` first (the bulk of the noise and the only safely
# deletable class), then the ones needing a human decision, then the informational ones.
function Get-DoctorClassOrder {
    return @(
        [pscustomobject]@{ Class='merged';          Label='Mergeadas (PR MERGED + tip coincide) - borrables'; Color='Green'      }
        [pscustomobject]@{ Class='closed-unmerged'; Label='PR cerrado sin mergear - decide';                  Color='Yellow'     }
        [pscustomobject]@{ Class='stale';           Label='Sin PR y estancadas';                              Color='Yellow'     }
        [pscustomobject]@{ Class='merged-advanced'; Label='PR mergeado pero con commits encima';              Color='DarkYellow' }
        [pscustomobject]@{ Class='dirty';           Label='Worktree con cambios sin commitear (esperado)';    Color='DarkYellow' }
        [pscustomobject]@{ Class='in-review';       Label='En review (PR abierto)';                           Color='Cyan'       }
        [pscustomobject]@{ Class='active';          Label='Sesion viva';                                      Color='Cyan'       }
        [pscustomobject]@{ Class='working';         Label='Trabajo reciente sin PR';                          Color='DarkGray'   }
    )
}

# ---------------------------------------------------------- -Fix sweep helpers (testable)
#
# These sit ABOVE the dot-source guard on purpose: Remove-BranchAndWorktree used to live below it,
# inline in the script body, so the only tests it ever had were greps over its source text - which
# is how a sweep that aborts on the first stuck worktree (#548) shipped without a failing test.

# Everything the -Fix sweep declined to do, so the END of the run can name it (#548). A skip used to
# be one DarkYellow line scrolling past in the middle of a long run, and one kind of "skip" was an
# abort that silently took every later branch with it - the run then read as "it did nothing".
# Process-lifetime state: each real run of this script is a fresh process, so it starts empty; anything
# that dot-sources the script more than once in one process (the tests) must reset both first.
$script:DoctorSkipped = @()
$script:DoctorDeleted = 0
function Add-DoctorSkip {
    param([string]$Branch, [string]$Reason)
    $script:DoctorSkipped += [pscustomobject]@{ Branch = $Branch; Reason = $Reason }
}

# Run git and NEVER let its failure become an exception of ours (#548). Under
# $ErrorActionPreference = 'Stop', Windows PowerShell 5.1 turns a native command's stderr into a
# TERMINATING error the moment it is redirected with 2>&1 - and PowerShell 7 does the same for any
# non-zero exit when $PSNativeCommandUseErrorActionPreference is on. `git worktree remove --force`
# on a tree the OS will not let go of writes to stderr, so the very first stuck worktree aborted the
# whole sweep. Failure is data here: the caller reads ExitCode and decides (skip, keep, continue).
# Lines keeps the raw output (porcelain needs its newlines); Output is the one-line form for messages.
function Invoke-GitQuiet {
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @()
    $code = -1
    try {
        $lines = @(& git @GitArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$_")
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
        Output   = ($lines -join ' ').Trim()
    }
}

# A worktree git already gave up on (`prunable`) whose DIRECTORY is still on disk (#548). This is the
# half-removed state a failed `git worktree remove --force` leaves on Windows: git deletes the
# worktree's `.git` link, then cannot delete the tree (a handle, a path past MAX_PATH). It is NOT the
# ghost that `git worktree prune` cures - the folder has content - and retrying the same
# `git worktree remove` cannot converge, so it is reported with the command that does clear it.
function Get-HalfRemovedWorktrees {
    param(
        [object[]]$Records = @(),
        [scriptblock]$PathExists = { param($p) Test-Path -LiteralPath $p }
    )
    return @($Records | Where-Object { $_.Prunable -and $_.Path -and (& $PathExists $_.Path) })
}

# The commands that clear a half-removed worktree. `Remove-Item -Recurse` fails past MAX_PATH and
# `rm -rf` fails on locked node_modules; robocopy /MIR from an empty folder is the one that handles
# long paths natively (measured in #548).
function Get-HalfRemovedHint {
    param([Parameter(Mandatory)][string]$Path)
    if ($null -eq $IsWindows -or $IsWindows) {
        return "robocopy `"$env:TEMP\abios-empty`" `"$Path`" /MIR ; rmdir `"$Path`" ; git worktree prune   (crea antes la carpeta vacia: mkdir `"$env:TEMP\abios-empty`")"
    }
    return "rm -rf `"$Path`" ; git worktree prune"
}

# The end-of-run account of a -Fix pass (#548). Pure: every fact arrives as an argument, so the
# wording that reaches the human is pinned by tests. Returns @{ Lines = string[]; HadSkips = bool }.
function Get-DoctorFixSummary {
    param(
        [int]$Deleted = 0,
        [object[]]$Skipped = @(),
        [object[]]$HalfRemoved = @(),
        [bool]$DryRun = $false
    )
    $lines = @()
    $skipped = @($Skipped | Where-Object { $_ })
    $half = @($HalfRemoved | Where-Object { $_ })
    $verb = if ($DryRun) { 'se borrarian' } else { 'borradas' }
    $lines += "Resumen: $Deleted rama(s) $verb, $($skipped.Count) omitida(s)."
    if ($skipped.Count -gt 0) {
        $lines += "  Omitidas (siguen ahi; el resto del barrido SI se hizo):"
        foreach ($s in $skipped) { $lines += ("    {0,-48} {1}" -f $s.Branch, $s.Reason) }
    }
    if ($half.Count -gt 0) {
        $lines += "  Worktrees a medio borrar (git ya los solto, la carpeta sigue con contenido) - reintentar 'git worktree remove' no los arregla:"
        foreach ($h in $half) {
            $lines += "    $($h.Path)"
            $lines += "      -> $(Get-HalfRemovedHint -Path $h.Path)"
        }
    }
    return @{ Lines = @($lines); HadSkips = ($skipped.Count -gt 0 -or $half.Count -gt 0) }
}

# Delete one branch and, when it has one, its worktree. Returns the list of things done/planned.
# NEVER throws: a failure is recorded with Add-DoctorSkip and the sweep carries on (#548).
function Remove-BranchAndWorktree {
    param([object]$Row, [string]$BranchFlag)
    $did = @()
    try {
        # FAIL CLOSED on uncommitted work, whatever the class says. A MERGED PR proves the
        # BRANCH landed; it proves nothing about files still sitting dirty in the worktree, and
        # `worktree remove --force` would silently destroy them. This is the #276/#277 rule, and
        # it matters most exactly here: a yes-to-all over 57 merged branches must not be able to
        # take a dirty one with it. Unreadable ('unknown') counts as dirty - never as clean.
        if ($Row.Dirty -eq 'dirty' -or $Row.Dirty -eq 'unknown') {
            $why = if ($Row.Dirty -eq 'dirty') { "tiene cambios sin commitear" } else { "no pude comprobar si tiene cambios [git status fallo]" }
            Write-Host "     SKIP conservo $($Row.Branch): su worktree $why. Revisalo a mano." -ForegroundColor DarkYellow
            Add-DoctorSkip -Branch $Row.Branch -Reason "su worktree $why"
            return $did
        }
        if ($Row.WorktreePath) {
            if ($here -and ((Resolve-Path $Row.WorktreePath -ErrorAction SilentlyContinue).Path -eq $here)) {
                Write-Host "     SKIP es el worktree actual - no me borro a mi mismo." -ForegroundColor DarkYellow
                Add-DoctorSkip -Branch $Row.Branch -Reason "es el worktree actual"
                return $did
            }
            # Half-removed by an EARLIER run (#548): retrying the same removal cannot converge, so
            # say what does instead of failing the same way again. Read-only, so -DryRun sees it too.
            $pre = Invoke-GitQuiet -GitArgs @('worktree', 'list', '--porcelain')
            if ($pre.ExitCode -eq 0) {
                $half = @(Get-HalfRemovedWorktrees -Records (Get-WorktreeRecords -Porcelain ($pre.Lines -join "`n")) |
                          Where-Object { $_.Branch -eq $Row.Branch -or ($_.Path -replace '\\', '/').TrimEnd('/') -eq ($Row.WorktreePath -replace '\\', '/').TrimEnd('/') })
                if ($half.Count -gt 0) {
                    Write-Host "     SKIP $($Row.Branch): su worktree quedo a medio borrar (git lo solto, la carpeta sigue). Vea el resumen final." -ForegroundColor DarkYellow
                    Add-DoctorSkip -Branch $Row.Branch -Reason "worktree a medio borrar: $(Get-HalfRemovedHint -Path $Row.WorktreePath)"
                    return $did
                }
            }
            $did += "git worktree remove --force $($Row.WorktreePath)"
            if (-not $DryRun) {
                # Ask GIT whether the removal took, not the filesystem (#287). An empty folder left
                # behind by an open handle is not a failed removal, and treating it as one kept a
                # proven-merged branch and forced a second -Fix pass over the 58-branch cleanup.
                # Resolve the path into git's own form first, while the directory still exists to
                # resolve from - otherwise a DETACHED worktree whose path spells differently is
                # invisible to both signals and reads as "gone" (#291). See Resolve-GitPathForm.
                $wtPathForGit = Resolve-GitPathForm $Row.WorktreePath
                # The exit code is deliberately ignored: the verdict is the listing below.
                Invoke-GitQuiet -GitArgs @('worktree', 'remove', '--force', $Row.WorktreePath) | Out-Null
                $list = Invoke-GitQuiet -GitArgs @('worktree', 'list', '--porcelain')
                if ($list.ExitCode -ne 0) {
                    # FAIL CLOSED: "I could not ask git" is not "it is gone" (the #277 rule).
                    Write-Host "     FAIL no pude releer 'git worktree list' tras el remove - conservo la rama $($Row.Branch) por si acaso." -ForegroundColor Red
                    Add-DoctorSkip -Branch $Row.Branch -Reason "no pude releer 'git worktree list' tras el remove"
                    return $did
                }
                $after = ($list.Lines -join "`n")
                if (Test-WorktreeStillRegistered -Porcelain $after -Path $wtPathForGit -Branch $Row.Branch) {
                    $nowHalf = @(Get-HalfRemovedWorktrees -Records (Get-WorktreeRecords -Porcelain $after) |
                                 Where-Object { $_.Branch -eq $Row.Branch })
                    if ($nowHalf.Count -gt 0) {
                        Write-Host "     FAIL el worktree de $($Row.Branch) quedo a medio borrar - conservo la rama. Vea el resumen final." -ForegroundColor Red
                        Add-DoctorSkip -Branch $Row.Branch -Reason "worktree a medio borrar: $(Get-HalfRemovedHint -Path $Row.WorktreePath)"
                    } else {
                        Write-Host "     FAIL git sigue registrando el worktree de $($Row.Branch) (handle abierto? locked?) - conservo la rama." -ForegroundColor Red
                        Add-DoctorSkip -Branch $Row.Branch -Reason "git sigue registrando su worktree (handle abierto? locked?)"
                    }
                    return $did
                }
                if (Test-Path $Row.WorktreePath) {
                    # Litter, not a blocker: git let it go, so the branch is safe to delete.
                    Write-Host "     NOTA git solto el worktree pero la carpeta sigue en disco (handle abierto?) - borro la rama igual; borra la carpeta a mano: $($Row.WorktreePath)" -ForegroundColor DarkYellow
                }
            }
        }
        $did += "git branch $BranchFlag $($Row.Branch)"
        if (-not $DryRun) {
            $del = Invoke-GitQuiet -GitArgs @('branch', $BranchFlag, $Row.Branch)
            if ($del.ExitCode -ne 0) {
                Write-Host "     WARN conservo la rama $($Row.Branch): git no la borro [$($del.Output)]" -ForegroundColor DarkYellow
                Add-DoctorSkip -Branch $Row.Branch -Reason "git no la borro [$($del.Output)]"
            } else {
                $script:DoctorDeleted++
            }
        }
    } catch {
        # Whatever else goes wrong for THIS branch must not take the rest of the sweep with it.
        $msg = "$($_.Exception.Message)".Split("`n")[0].Trim()
        Write-Host "     FAIL $($Row.Branch): $msg - sigo con las demas." -ForegroundColor Red
        Add-DoctorSkip -Branch $Row.Branch -Reason "error inesperado: $msg"
    }
    return $did
}

# --------------------------------------------- installed-plugin drift (#482) - READ-ONLY
#
# "Which build is actually running?" had no answer anywhere in the tool. On 2026-07-28 the installed
# cache held scripts hand-patched with an unreleased fix while the cache and the published source
# both said `0.27.0`: an armed safety mechanism (the brake) lived only in that hand-patched copy, and
# a plain `claude plugin update` would have removed it without the version string moving. The rule
# "diagnose by commit sha, never by the version string" was written down and enforced nowhere.
#
# So this compares CONTENT. The installed plugin records the commit it was built from
# (installed_plugins.json -> gitCommitSha); the published tree at that commit is read from a local
# clone that holds it (the marketplace clone, or a dev checkout), and every installed file is
# compared with its published blob by git blob id. A version string is REPORTED, never trusted.
#
# It reports and never repairs: overwriting a deliberate local patch would be its own incident. And
# it must be trustworthy in BOTH directions - a clean install must say clean, a check that cries wolf
# is worse than none - so anything it cannot verify is `unverifiable`, never `clean`.

# git's blob id for some bytes: sha1("blob <len>\0" + content). Assumes git's default SHA-1 object
# format (a repo created with --object-format=sha256 would read as drifted/unverifiable, never clean). Lets an installed file be compared
# with a tree entry WITHOUT shelling out to git once per file.
function Get-GitBlobSha {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $hdr = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $all = New-Object byte[] ($hdr.Length + $Bytes.Length)
    [System.Array]::Copy($hdr, 0, $all, 0, $hdr.Length)
    [System.Array]::Copy($Bytes, 0, $all, $hdr.Length, $Bytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { return (($sha1.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha1.Dispose() }
}

# Both spellings of one file's content: as found on disk (Raw) and with every CRLF folded to LF
# (Lf). The published blobs are LF (the repo is checked in LF), but a clone made with
# core.autocrlf=true and copied into the plugin cache carries CRLF - measured on the primary machine
# (`i/lf w/crlf`). Matching either one is what keeps a CLEAN install from reading as drifted; a
# file whose CONTENT differs matches neither.
function Get-FileBlobShas {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $raw = Get-GitBlobSha -Bytes $bytes
    $lf = $raw
    if ([System.Array]::IndexOf($bytes, [byte]13) -ge 0) {
        $folded = New-Object 'System.Collections.Generic.List[byte]' $bytes.Length
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
            $folded.Add($bytes[$i])
        }
        $lf = Get-GitBlobSha -Bytes $folded.ToArray()
    }
    return @{ Raw = $raw; Lf = $lf }
}

# relative path (forward slashes) -> @{ Raw; Lf } for every file under a directory. Hidden files
# included: the runtime markers live in a dot-directory, and so could a hand-added file.
function Get-InstalledTreeHashes {
    param([Parameter(Mandatory)][string]$Root)
    $map = @{}
    $rootFull = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\', '/')
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        $map[$rel] = Get-FileBlobShas -Path $f.FullName
    }
    return $map
}

# relative path -> blob id for a subdirectory of a commit, from a local repo. $null when git cannot
# answer (no such commit in that clone, no such path) - the caller treats that as unverifiable.
function Get-PublishedBlobMap {
    param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Sha, [Parameter(Mandatory)][string]$Subdir)
    $r = Invoke-GitQuiet -GitArgs @('-C', $RepoPath, '-c', 'core.quotepath=off', 'ls-tree', '-r', '-z', "${Sha}:$Subdir")
    if ($r.ExitCode -ne 0) { return $null }
    $map = @{}
    foreach ($e in (($r.Lines -join '') -split "`0")) {
        if ($e -match '^\d+ \w+ ([0-9a-f]{40})\t(.+)$') { $map[$Matches[2]] = $Matches[1] }
    }
    if ($map.Count -eq 0) { return $null }
    return $map
}

# PURE: what differs between an installed tree and the published one. Installed: rel -> @{Raw;Lf}.
# Published: rel -> blob id. A file is Modified when NEITHER spelling of its content is the published
# blob. Extra excludes -IgnorePrefix (Claude Code's own runtime markers, `.in_use/<pid>`, are not the
# plugin's content); Missing is a published file absent from the install.
function Compare-PluginTree {
    param(
        [Parameter(Mandatory)][hashtable]$Installed,
        [Parameter(Mandatory)][hashtable]$Published,
        [string[]]$IgnorePrefix = @('.in_use/')
    )
    $mod = @(); $extra = @(); $miss = @()
    foreach ($k in ($Installed.Keys | Sort-Object)) {
        if (@($IgnorePrefix | Where-Object { $k.StartsWith($_, [System.StringComparison]::Ordinal) }).Count -gt 0) { continue }
        if (-not $Published.ContainsKey($k)) { $extra += $k; continue }
        $h = $Installed[$k]
        if ($Published[$k] -ne $h.Raw -and $Published[$k] -ne $h.Lf) { $mod += $k }
    }
    foreach ($k in ($Published.Keys | Sort-Object)) {
        if (-not $Installed.ContainsKey($k)) { $miss += $k }
    }
    return [pscustomobject]@{ Modified = @($mod); Extra = @($extra); Missing = @($miss) }
}

# The plugin's own `version` at a commit, read from the published tree.
function Get-PublishedVersion {
    param([string]$RepoPath, [string]$Sha, [string]$Subdir)
    $r = Invoke-GitQuiet -GitArgs @('-C', $RepoPath, 'show', "${Sha}:$Subdir/.claude-plugin/plugin.json")
    if ($r.ExitCode -ne 0) { return '' }
    try { return "$((($r.Lines -join "`n") | ConvertFrom-Json).version)" } catch { return '' }
}

# The installed record for a plugin from installed_plugins.json: { Key; InstallPath; Version; Sha }
# or $null. When several marketplaces carry the same plugin name the FIRST entry in the file wins
# ($PluginName may also be given as the full `<plugin>@<marketplace>` key to pick one).
function Get-InstalledPluginRecord {
    param([Parameter(Mandatory)][string]$InstalledJson, [Parameter(Mandatory)][string]$PluginName)
    if (-not (Test-Path -LiteralPath $InstalledJson)) { return $null }
    try { $doc = Get-Content -LiteralPath $InstalledJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $doc.plugins) { return $null }
    foreach ($p in $doc.plugins.PSObject.Properties) {
        if ($p.Name -ne $PluginName -and -not $p.Name.StartsWith("$PluginName@", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $entry = @($p.Value) | Select-Object -First 1
        if (-not $entry) { continue }
        return [pscustomobject]@{
            Key = $p.Name; InstallPath = "$($entry.installPath)"; Version = "$($entry.version)"; Sha = "$($entry.gitCommitSha)"
            Marketplace = ($p.Name -split '@', 2)[1]
        }
    }
    return $null
}

# Compare the installed plugin with the build it claims to be. Returns one object:
#   Status   clean | drifted | unverifiable | not-installed
#   Reason   why, when it is not clean
#   InstalledVersion / InstalledSha / PublishedVersion (the tree at that sha) / ChannelVersion
#   Modified / Extra / Missing   file lists (drifted only)
# -CandidateRepos are local git clones searched, in order, for the recorded commit.
function Get-PluginDrift {
    param(
        [string]$PluginName = 'agentic-board',
        [string]$Subdir = 'plugins/agentic-board',
        [string]$InstalledJson = '',
        [string[]]$CandidateRepos = @()
    )
    $home_ = [Environment]::GetFolderPath('UserProfile')
    if (-not $InstalledJson) { $InstalledJson = Join-Path (Join-Path (Join-Path $home_ '.claude') 'plugins') 'installed_plugins.json' }
    $res = [ordered]@{
        Status = 'unverifiable'; Reason = ''; InstalledVersion = ''; InstalledSha = ''; InstalledPath = ''
        PublishedVersion = ''; ChannelVersion = ''; Modified = @(); Extra = @(); Missing = @()
    }
    $rec = Get-InstalledPluginRecord -InstalledJson $InstalledJson -PluginName $PluginName
    if (-not $rec) { $res.Status = 'not-installed'; $res.Reason = "no hay '$PluginName' en $InstalledJson"; return [pscustomobject]$res }
    $res.InstalledVersion = $rec.Version; $res.InstalledSha = $rec.Sha; $res.InstalledPath = $rec.InstallPath
    if (-not $rec.Sha) { $res.Reason = "la instalacion no registra gitCommitSha - no hay build publicado contra el que comparar"; return [pscustomobject]$res }
    if (-not $rec.InstallPath -or -not (Test-Path -LiteralPath $rec.InstallPath -PathType Container)) {
        $res.Reason = "la carpeta instalada no existe: $($rec.InstallPath)"; return [pscustomobject]$res
    }
    # The marketplace clone first (that is where the published build lives), then any other clone.
    $repos = @($CandidateRepos | Where-Object { $_ })
    $published = $null; $usedRepo = ''
    foreach ($r in $repos) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $m = Get-PublishedBlobMap -RepoPath $r -Sha $rec.Sha -Subdir $Subdir
        if ($m) { $published = $m; $usedRepo = $r; break }
    }
    if (-not $published) {
        $res.Reason = "el commit $($rec.Sha.Substring(0, [Math]::Min(7, $rec.Sha.Length))) no esta en ningun clon local ($($repos.Count) buscados). Actualiza el clon del marketplace (git -C <clon> fetch) y reintenta"
        return [pscustomobject]$res
    }
    $res.PublishedVersion = Get-PublishedVersion -RepoPath $usedRepo -Sha $rec.Sha -Subdir $Subdir
    $chan = Invoke-GitQuiet -GitArgs @('-C', $usedRepo, 'rev-parse', '--verify', '--quiet', 'refs/remotes/origin/release^{commit}')
    if ($chan.ExitCode -eq 0 -and $chan.Output) { $res.ChannelVersion = Get-PublishedVersion -RepoPath $usedRepo -Sha $chan.Output -Subdir $Subdir }
    $diff = Compare-PluginTree -Installed (Get-InstalledTreeHashes -Root $rec.InstallPath) -Published $published
    $res.Modified = @($diff.Modified); $res.Extra = @($diff.Extra); $res.Missing = @($diff.Missing)
    if ($diff.Modified.Count -eq 0 -and $diff.Extra.Count -eq 0 -and $diff.Missing.Count -eq 0) {
        $res.Status = 'clean'
    } else {
        $res.Status = 'drifted'
        $res.Reason = "$($diff.Modified.Count) archivo(s) modificado(s), $($diff.Extra.Count) de mas, $($diff.Missing.Count) ausente(s) respecto al build publicado"
    }
    return [pscustomobject]$res
}

# The report lines. Pure, so the wording that reaches the human is pinned by tests.
function Format-PluginDrift {
    param([Parameter(Mandatory)]$Drift)
    $short = { param($s) if ($s) { $s.Substring(0, [Math]::Min(7, $s.Length)) } else { '?' } }
    $ver = "instalado $($Drift.InstalledVersion) @ $(& $short $Drift.InstalledSha)"
    if ($Drift.PublishedVersion) { $ver += " | publicado en ese commit: $($Drift.PublishedVersion)" }
    if ($Drift.ChannelVersion)   { $ver += " | canal release: $($Drift.ChannelVersion)" }
    $lines = @()
    switch ($Drift.Status) {
        'clean'         { $lines += "OK  el plugin instalado coincide byte a byte con el build publicado ($ver)" }
        'not-installed' { $lines += "--  $($Drift.Reason)" }
        'unverifiable'  { $lines += "??  no pude verificar el plugin instalado ($ver): $($Drift.Reason)" }
        'drifted' {
            $lines += "!!  el plugin instalado NO coincide con su build publicado ($ver): $($Drift.Reason)"
            $lines += "    Se compara el CONTENIDO, no la version: la misma cadena de version puede esconder un parche local."
            foreach ($f in $Drift.Modified) { $lines += "      modificado  $f" }
            foreach ($f in $Drift.Extra)    { $lines += "      de mas      $f" }
            foreach ($f in $Drift.Missing)  { $lines += "      ausente     $f" }
            $lines += "    Solo informa: 'claude plugin update' sobrescribiria un parche local deliberado (podria quitar lo que solo vive en tu copia)."
        }
    }
    return @($lines)
}

# Dot-source guard: with $env:ABIOS_DOCTOR_DOTSOURCE set, return after defining the pure
# helpers WITHOUT touching disk, git, gh or the token - lets the tests unit-test them.
if ($env:ABIOS_DOCTOR_DOTSOURCE) { return }

# ------------------------------------------------------------- live (side-effecting)

# -- Token (respect GH_TOKEN if gh-account already set it) ---------------------
if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

if (-not (git rev-parse --git-dir 2>$null)) { throw "Not inside a git repository." }

if (-not $Repo) { $Repo = Get-RepoFromOrigin }

Write-Host ""
Write-Host "=== /board doctor - inventario de ramas y worktrees ($Repo) ===" -ForegroundColor Cyan
Write-Host "    Fuente: git refs + PRs de GitHub. sessions.json NO decide nada aqui" -ForegroundColor DarkGray
Write-Host "    (solo marca sesiones vivas para protegerlas)." -ForegroundColor DarkGray
Write-Host ""

# The remote's real default branch - never audit it, whatever it is called.
$defaultBranch = ""
try {
    $rv = gh repo view $Repo --json defaultBranchRef 2>$null | ConvertFrom-Json
    if ($rv) { $defaultBranch = $rv.defaultBranchRef.name }
} catch { }
$protected = @('main','master','develop') + $Protect
if ($defaultBranch) { $protected += $defaultBranch }
$protected = @($protected | Where-Object { $_ } | Select-Object -Unique)

# --- git: the branch inventory -------------------------------------------------
# Fail closed here too, for the same reason as the PR listing: a failed for-each-ref returns
# nothing, which is indistinguishable from "this repo has no branches" and would print a
# reassuring empty audit. An empty answer we cannot vouch for is not an answer.
$refLines = @(git for-each-ref --format='%(refname:short)|%(objectname)|%(committerdate:iso8601)' refs/heads 2>$null)
if ($LASTEXITCODE -ne 0) { throw "'git for-each-ref' fallo - no puedo inventariar las ramas locales, y un inventario vacio se leeria como 'no hay nada que limpiar'." }
$branches = @()
foreach ($l in $refLines) {
    $parts = $l -split '\|', 3
    if ($parts.Count -lt 3) { continue }
    $name = $parts[0]
    if ($protected -contains $name) { continue }
    if ($name -notlike $Prefix)     { continue }
    $when = [datetime]::MinValue
    try { $when = [datetime]::Parse($parts[2]) } catch { }
    $branches += [pscustomobject]@{ Name = $name; Tip = $parts[1]; CommitDate = $when }
}

# --- git: the worktree inventory ----------------------------------------------
# Fail closed: if this fails, every branch looks worktree-less, which silently switches OFF the
# dirty-files guard and the "never delete my own worktree" guard - the two things standing
# between -Fix and someone's uncommitted work.
$wtPorcelain = (git worktree list --porcelain 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "'git worktree list' fallo - sin el inventario de worktrees no puedo saber cuales tienen cambios sin commitear, asi que no es seguro seguir." }
$wtRecords = Get-WorktreeRecords -Porcelain $wtPorcelain
$wtByBranch = @{}
foreach ($w in $wtRecords) { if ($w.Branch) { $wtByBranch[$w.Branch] = $w } }
# Ghost worktrees: git itself flags a registered worktree whose directory is gone. A prunable one
# whose directory is STILL THERE is a different animal (#548): half-removed, with content, so it is
# reported with its own remedy instead of being promised a `git worktree prune` that leaves the folder.
$halfRemoved = @(Get-HalfRemovedWorktrees -Records $wtRecords)
$ghosts = @($wtRecords | Where-Object { $_.Prunable -and ($halfRemoved.Path -notcontains $_.Path) })
# The INVERSE case git cannot flag, because it no longer knows the worktree exists: the
# directory survives under .claude/worktrees/ with a broken .git link, so it never appears in
# the porcelain above and never becomes a record to mark prunable (#618). Reported, not fixed
# here - the empty ones are swept by the SessionStart hook, and the ones with content need a
# human. Best-effort: a failure to inventory orphans must never sink the branch audit.
$orphans = @()
$staleRegistry = @()
try {
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = '1'
    . (Join-Path $PSScriptRoot 'Worktree-Ghosts.ps1')
    $env:ABIOS_WORKTREE_GHOSTS_DOTSOURCE = ''

    $orphans = @(Get-WorktreeGhosts -RepoRoot '.' -Porcelain $wtPorcelain)

    # The retry loop these orphans feed is driven by a MACHINE-WIDE registry, so an orphan in
    # another repo keeps it running where no single invocation of this command would ever look.
    $regEntries = @(Get-RegistryWorktrees)
    $existsMap = @{}
    foreach ($e in $regEntries) {
        if ($e.Path) { $existsMap[(ConvertTo-ComparablePath $e.Path)] = (Test-Path -LiteralPath $e.Path) }
    }
    $staleRegistry = @(Select-StaleRegistryEntries -Entries $regEntries -ExistsMap $existsMap)
} catch { }
# Never offer to tear down the worktree we are standing in.
$here = ""
try { $here = (Resolve-Path (git rev-parse --show-toplevel 2>$null) -ErrorAction SilentlyContinue).Path } catch { }

# --- gh: every PR, once -------------------------------------------------------
# FAIL CLOSED, loudly. The PRs are the ONLY proof of merge here (ancestry is useless against a
# squash merge), so a failed/partial listing is not "this repo has no PRs" - it is "we do not
# know anything". Swallowing it would reclassify every merged branch as `stale` and hand -Fix a
# list of 57 branches to offer for deletion. gh exits non-zero on auth/network failure without
# throwing, so check the exit code explicitly rather than relying on a catch.
$prsByBranch = @{}
$prJson = $null
try { $prJson = gh pr list --repo $Repo --state all --limit $PrLimit --json number,state,headRefName,headRefOid 2>$null } catch { }
if ($LASTEXITCODE -ne 0 -or $null -eq $prJson) {
    throw "No pude listar los PRs de $Repo (gh fallo). Sin ellos el veredicto de merge no es fiable: este repo squash-mergea, asi que la ancestria de git no puede sustituirlos. Revisa el token y el acceso al repo, y reintenta."
}
$allPrs = @()
try { $allPrs = @($prJson | ConvertFrom-Json) } catch {
    throw "La respuesta de 'gh pr list' para $Repo no es JSON valido - no puedo verificar que ramas estan mergeadas. $_"
}
# NO SILENT CAPS. Hitting -PrLimit means the listing is truncated, and a merged PR that fell off
# the end reads as "this branch has no PR" -> stale -> offered for deletion. A truncated answer
# is an unknown answer, so refuse it the same way a gh failure is refused (#246).
if ($allPrs.Count -ge $PrLimit) {
    throw "'gh pr list' devolvio $($allPrs.Count) PRs y toco el limite de ${PrLimit}: la lista podria estar truncada, y un PR mergeado que se caiga del corte haria que su rama parezca 'sin PR' (y -Fix ofreceria borrarla). Sube -PrLimit por encima del total de PRs del repo y reintenta."
}
foreach ($p in $allPrs) {
    if (-not $p.headRefName) { continue }
    if (-not $prsByBranch.ContainsKey($p.headRefName)) { $prsByBranch[$p.headRefName] = @() }
    $prsByBranch[$p.headRefName] += $p
}

# --- registry: protection only ------------------------------------------------
# The registry never decides what EXISTS - but it is the only thing that marks a branch as
# owned by a live session, and that is a veto over deletion. So "unreadable" must not collapse
# into "no live sessions": Read-SessionRegistry returns @() for BOTH, and a merged branch that
# a live session is still working would then land in the deletable pile. Parse-check the file
# ourselves and remember whether the answer is trustworthy; -Fix refuses if it is not.
$liveBranches = @()
$registryTrusted = $true
try {
    $regPath = Get-SessionRegistryPath
    if ($regPath -and (Test-Path $regPath)) {
        $null = Get-Content $regPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    $liveBranches = @(Read-SessionRegistry | ForEach-Object { $_.branch } | Where-Object { $_ })
} catch {
    $registryTrusted = $false
}

# --- classify -----------------------------------------------------------------
$now = Get-Date
# Installed plugin vs the build it claims to be (#482). Read-only and best-effort: a check that
# cannot run must never sink the branch audit, and it never repairs anything.
$pluginDrift = $null
try {
    $mpClone = ''
    try {
        $kmPath = Join-Path (Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude') 'plugins') 'known_marketplaces.json'
        if (Test-Path -LiteralPath $kmPath) {
            $km = Get-Content -LiteralPath $kmPath -Raw | ConvertFrom-Json
            $mpClone = "$($km.'agentic-board'.installLocation)"
        }
    } catch { }
    $devClone = ''
    try { $devClone = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path } catch { }
    $pluginDrift = Get-PluginDrift -CandidateRepos @($mpClone, $devClone)
} catch { $pluginDrift = $null }

$rows = @()
foreach ($b in $branches) {
    $wt = $wtByBranch[$b.Name]
    $wtPath = if ($wt) { $wt.Path } else { '' }
    # Dirty state is only knowable for a branch that HAS a live worktree directory. Fail
    # closed: an unreadable worktree must not read as "clean" (the #277 rule).
    $dirty = 'clean'
    if ($wtPath -and -not $wt.Prunable) {
        # --untracked-files=all is NOT redundant: `status.showUntrackedFiles=no` in the user's
        # config makes a bare --porcelain report a worktree full of untracked scratch files as
        # CLEAN, and the removal below runs --force. Pin the mode instead of inheriting config.
        $exists = [bool](Test-Path $wtPath)
        $out = if ($exists) { @(git -C $wtPath status --porcelain --untracked-files=all 2>&1) } else { @() }
        $dirty = Get-WorktreeDirtyState -ExitCode $(if ($exists) { $LASTEXITCODE } else { 0 }) -StatusLines $out -PathExists $exists
    }
    $rows += Get-BranchClass -Name $b.Name -Tip $b.Tip -Prs @($prsByBranch[$b.Name]) `
        -CommitDate $b.CommitDate -Now $now -StaleDays $StaleDays `
        -HasLiveSession ([bool]($liveBranches -contains $b.Name)) `
        -WorktreePath $wtPath -Dirty $dirty
}

if ($Json) {
    [pscustomobject]@{
        repo = $Repo; generatedAt = $now.ToString('o'); staleDays = $StaleDays
        branches = @($rows); ghostWorktrees = @($ghosts | Select-Object Path, Prunable)
        halfRemovedWorktrees = @($halfRemoved | Select-Object Path, Branch, Prunable)
        pluginDrift = $pluginDrift
        orphanWorktrees = @($orphans | Select-Object Name, Path, Class, AutoRemovable)
        staleRegistryEntries = @($staleRegistry | Select-Object Name, Path)
    } | ConvertTo-Json -Depth 6
    exit 0
}

# --- report -------------------------------------------------------------------
Write-Host "  $($branches.Count) ramas locales auditadas | $($prsByBranch.Keys.Count) ramas con PR | $($wtRecords.Count) worktrees" -ForegroundColor DarkGray
Write-Host ""

foreach ($c in Get-DoctorClassOrder) {
    $inClass = @($rows | Where-Object { $_.Class -eq $c.Class })
    if ($inClass.Count -eq 0) { continue }
    Write-Host "--- $($c.Label) ($($inClass.Count)) ---" -ForegroundColor $c.Color
    foreach ($r in ($inClass | Sort-Object Branch)) {
        # Flag the dirty worktree even on a class that is otherwise deletable: -Fix will
        # refuse it, so the reader must see WHY it survives the cleanup.
        $wtNote = switch ($r.Dirty) {
            'dirty'   { "  [worktree: cambios sin commitear -> -Fix lo conserva]" }
            'unknown' { "  [worktree: no pude leer su estado -> -Fix lo conserva]" }
            default   { if ($r.WorktreePath) { "  [worktree]" } else { "" } }
        }
        Write-Host ("   {0,-52} {1}{2}" -f $r.Branch, $r.Reason, $wtNote)
    }
    Write-Host ""
}

if ($ghosts.Count -gt 0) {
    Write-Host "--- Worktrees fantasma (carpeta ausente) ($($ghosts.Count)) ---" -ForegroundColor Yellow
    foreach ($g in $ghosts) { Write-Host ("   {0,-52} {1}" -f $g.Path, $g.Prunable) }
    Write-Host "    Se limpian solos al correr con -Fix (no hay trabajo que perder, git ya sabe que desaparecieron)." -ForegroundColor DarkGray
    Write-Host ""
}

if ($halfRemoved.Count -gt 0) {
    Write-Host "--- Worktrees a medio borrar (git los solto, la carpeta sigue con contenido) ($($halfRemoved.Count)) ---" -ForegroundColor Red
    foreach ($h in $halfRemoved) { Write-Host ("   {0,-52} {1}" -f $h.Branch, $h.Path) }
    Write-Host "    Reintentar 'git worktree remove' no converge. Lo que si los limpia (long paths / node_modules):" -ForegroundColor DarkGray
    foreach ($h in $halfRemoved) { Write-Host "      $(Get-HalfRemovedHint -Path $h.Path)" -ForegroundColor DarkGray }
    Write-Host ""
}

# The plugin that is actually installed vs the build it says it is (#482).
if ($pluginDrift -and $pluginDrift.Status -ne 'not-installed') {
    $driftColor = switch ($pluginDrift.Status) { 'clean' { 'Green' } 'drifted' { 'Red' } default { 'Yellow' } }
    Write-Host "--- Plugin instalado vs build publicado ---" -ForegroundColor $driftColor
    foreach ($l in (Format-PluginDrift -Drift $pluginDrift)) { Write-Host "   $l" -ForegroundColor $driftColor }
    Write-Host ""
}

# The inverse ghosts (#618). Split by class, because the two demand opposite responses: the
# empty ones are already handled automatically, the ones with content are a question for you.
$orphanContent = @($orphans | Where-Object { $_.Class -eq 'orphan-content' })
$orphanEmpty   = @($orphans | Where-Object { $_.Class -eq 'orphan-empty' })

if ($orphanContent.Count -gt 0) {
    Write-Host "--- Worktrees huerfanos CON CONTENIDO (carpeta presente, git no los conoce) ($($orphanContent.Count)) ---" -ForegroundColor Red
    foreach ($o in $orphanContent) { Write-Host ("   {0,-52} {1}" -f $o.Name, $o.Path) }
    Write-Host "    Git ya podo su metadata, asi que 'git worktree prune' no los ve." -ForegroundColor DarkGray
    Write-Host "    Tienen archivos: revisalos a mano antes de borrar nada." -ForegroundColor DarkGray
    Write-Host ""
}

if ($orphanEmpty.Count -gt 0) {
    Write-Host "--- Worktrees huerfanos vacios ($($orphanEmpty.Count)) ---" -ForegroundColor Yellow
    foreach ($o in $orphanEmpty) { Write-Host ("   {0,-52} {1}" -f $o.Name, $o.Path) }
    Write-Host "    El hook de SessionStart los barre solo en el proximo arranque." -ForegroundColor DarkGray
    Write-Host ""
}

if ($staleRegistry.Count -gt 0) {
    Write-Host "--- Entradas muertas en el registro global ($($staleRegistry.Count)) ---" -ForegroundColor Yellow
    Write-Host "    Su ruta ya no existe. Alimentan el ciclo de reintentos desde CUALQUIER repo," -ForegroundColor DarkGray
    Write-Host "    no solo este, por eso aparecen aunque no sean de aqui." -ForegroundColor DarkGray
    foreach ($s in $staleRegistry) { Write-Host ("   {0,-36} {1}" -f $s.Name, $s.Path) }
    Write-Host ""
}

$deletable = @($rows | Where-Object { $_.Deletable })
$decide    = @($rows | Where-Object { $_.Class -in @('closed-unmerged','stale') -and -not $_.HasLiveSession })

if (-not $Fix) {
    Write-Host "Read-only: no se cambio nada." -ForegroundColor DarkGray
    if ($deletable.Count -gt 0 -or $ghosts.Count -gt 0 -or $halfRemoved.Count -gt 0 -or $decide.Count -gt 0 -or $orphans.Count -gt 0 -or $staleRegistry.Count -gt 0) {
        Write-Host "  $($deletable.Count) rama(s) mergeadas borrables, $($decide.Count) por decidir, $($ghosts.Count) worktree(s) fantasma." -ForegroundColor DarkGray
        if ($orphans.Count -gt 0 -or $staleRegistry.Count -gt 0) {
            Write-Host "  $($orphanContent.Count) huerfano(s) con contenido, $($orphanEmpty.Count) vacio(s), $($staleRegistry.Count) entrada(s) muerta(s) en el registro global." -ForegroundColor DarkGray
        }
        Write-Host "  Ejecuta con -Fix para limpiarlas (confirma rama por rama; -Fix -DryRun para ver el plan)." -ForegroundColor DarkGray
        if ($orphanContent.Count -gt 0) {
            Write-Host "  -Fix NO toca los huerfanos con contenido: revisalos tu." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Nada que limpiar." -ForegroundColor Green
    }
    Write-Host ""
    exit 0
}

# --- -Fix ---------------------------------------------------------------------
# One message, two guards (up-front IsInputRedirected + the Read-Host catch) - they must say
# the same thing wherever the missing terminal is discovered (#285).
$script:NeedTty = "-Fix necesita una terminal interactiva: confirma rama por rama y aqui no hay donde preguntar. Opciones: -Fix -DryRun para ver el plan, -Fix -Auto para borrar solo las mergeadas (probadas seguras) sin preguntar, o corre esto en una terminal normal."
# Every branch is confirmed individually. `a` (todas) only ever applies within the class
# being walked, so a yes-to-all on the proven-merged pile can never spill into the unmerged
# ones - those are a separate walk with its own prompts, defaulting to No.
$script:Quit = $false
function Confirm-Branch {
    # PositionalBinding=$false + explicit Positions: -AutoOk is the switch that lets -Auto skip
    # a confirmation, so it must be IMPOSSIBLE to turn on by accident. Left positional, a future
    # `Confirm-Branch "..." ([ref]$x) 'n' $true` would silently bind $true to it and hand the
    # unmerged walk a free pass (Codex review, PR #286). Now it can only ever be named.
    [CmdletBinding(PositionalBinding=$false)]
    param(
        [Parameter(Position=0)][string]$Prompt,
        [Parameter(Position=1)][ref]$AllRef,
        [Parameter(Position=2)][string]$Default = 'n',
        [switch]$AutoOk
    )
    if ($script:Quit)  { return $false }
    # -DryRun writes nothing, so a prompt would only stand between the user and the plan they
    # asked to see - and would make the preview unusable non-interactively (CI, `pwsh -File`).
    # Answer yes to everything so the FULL plan prints; the guards below still run, so a keep
    # (dirty worktree, current worktree) is previewed as a keep.
    if ($DryRun)       { return $true }
    # -Auto only ever reaches here with $AutoOk, which ONLY the proven-merged walk passes.
    if ($Auto -and $AutoOk) { return $true }
    if ($AllRef.Value) { return $true }
    while ($true) {
        try {
            $ans = (Read-Host "$Prompt [s=si / n=no / t=todas / q=salir] ($Default)").Trim().ToLower()
        } catch {
            # `pwsh -NonInteractive` has no API to detect up front, so this is the real guard:
            # turn the raw "PowerShell is in NonInteractive mode" into the actionable message
            # (#285). Nothing has been deleted at this point - the delete follows the confirm.
            throw $script:NeedTty
        }
        if (-not $ans) { $ans = $Default }
        switch ($ans) {
            's' { return $true }
            'n' { return $false }
            't' { $AllRef.Value = $true; return $true }
            'q' { $script:Quit = $true; return $false }
        }
    }
}

# The read-only report is still honest with a broken registry (it just cannot say "active"), but
# -Fix leans on it to veto deleting a live session's branch. Without it, refuse to delete.
if (-not $registryTrusted) {
    throw "No pude leer .agentic-board/sessions.json (corrupto o bloqueado). Es lo unico que marca las ramas de sesiones vivas, y sin el una rama mergeada que otra sesion sigue trabajando entraria en la lista de borrado. Arregla o borra ese archivo y reintenta; el inventario read-only (sin -Fix) sigue funcionando."
}

# A real -Fix cannot run where Read-Host is unavailable (`pwsh -NonInteractive`, CI, a piped
# stdin): the per-branch confirmation IS the safety contract, so refuse UP FRONT rather than
# throw from the first prompt with branches already half-walked. -DryRun is fine - it asks
# nothing; -Auto is fine - it does not prompt for the merged class.
#
# Deliberately NOT the .NET UserInteractive flag: it reports TRUE under `pwsh -NonInteractive`,
# so the original guard never fired and Read-Host blew up mid-walk anyway - the exact thing it
# claimed to prevent (#285). IsInputRedirected catches piped stdin up front; the -NonInteractive
# case has no API at all, so Confirm-Branch catches the Read-Host failure and rethrows this
# message. A test asserts that flag never comes back.
if (-not $DryRun -and -not $Auto -and [System.Console]::IsInputRedirected) {
    throw $script:NeedTty
}

$mode = if ($DryRun) { "DRY-RUN - nada se ejecuta" }
        elseif ($Auto) { "-Fix -Auto - borra las mergeadas SIN preguntar (las sin mergear no se tocan)" }
        else { "-Fix - esto borra ramas y worktrees" }
Write-Host "=== $mode ===" -ForegroundColor Yellow
Write-Host ""

# 1) Proven-merged: safe, and the bulk of the pile. `-D` (not `-d`) is REQUIRED here and is
#    not a shortcut: the squash merge means git cannot see the merge, so `-d` refuses a branch
#    we have already PROVEN merged via the PR (#273/PR #275). The proof is the PR, not git.
$allMerged = $false
if ($deletable.Count -gt 0) {
    Write-Host "-- $($deletable.Count) rama(s) mergeadas (PR MERGED + tip coincide)" -ForegroundColor Green
    foreach ($r in ($deletable | Sort-Object Branch)) {
        if ($script:Quit) { break }
        # -AutoOk is passed HERE and nowhere else: this is the only class whose safety is proven
        # rather than judged, so it is the only one -Auto may skip the prompt for (#285).
        if (Confirm-Branch "   Borrar $($r.Branch) (PR #$($r.Pr) mergeado)?" ([ref]$allMerged) 's' -AutoOk) {
            foreach ($a in (Remove-BranchAndWorktree -Row $r -BranchFlag '-D')) { Write-Host "     $a" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
}

# 2) Unmerged: NEVER a yes-to-all, NEVER a default-yes. Each one is a separate decision and
#    the work is unrecoverable, so the prompt defaults to No and `t` is not offered.
if ($decide.Count -gt 0 -and -not $script:Quit -and $Auto) {
    # -Auto must never reach a prompt it cannot answer, and "cannot ask" must resolve to KEEP.
    # Listing them is the useful half; deleting unmerged work unattended is not on the table.
    Write-Host "-- $($decide.Count) rama(s) SIN MERGEAR: -Auto NO las toca (su trabajo no esta en ningun lado)" -ForegroundColor Yellow
    foreach ($r in ($decide | Sort-Object Branch)) { Write-Host "   $($r.Branch) - $($r.Reason)" -ForegroundColor DarkGray }
    Write-Host "   Revisalas con -Fix en una terminal interactiva." -ForegroundColor DarkGray
    Write-Host ""
} elseif ($decide.Count -gt 0 -and -not $script:Quit) {
    Write-Host "-- $($decide.Count) rama(s) SIN MERGEAR - el trabajo se pierde si las borras" -ForegroundColor Yellow
    $never = $false
    foreach ($r in ($decide | Sort-Object Branch)) {
        if ($script:Quit) { break }
        Write-Host "   $($r.Branch) - $($r.Reason)" -ForegroundColor Yellow
        if (Confirm-Branch "     Descartarla (irreversible)?" ([ref]$never) 'n') {
            foreach ($a in (Remove-BranchAndWorktree -Row $r -BranchFlag '-D')) { Write-Host "     $a" -ForegroundColor DarkGray }
        }
        $never = $false   # yes-to-all is deliberately not honored for unmerged work
    }
    Write-Host ""
}

# 3) Ghost worktrees: pure bookkeeping, no work can be lost - git already knows they are gone.
if ($ghosts.Count -gt 0 -and -not $script:Quit) {
    Write-Host "-- $($ghosts.Count) worktree(s) fantasma" -ForegroundColor Yellow
    Write-Host "   git worktree prune" -ForegroundColor DarkGray
    if (-not $DryRun) { git worktree prune 2>&1 | Out-Null; Write-Host "   OK  podados" -ForegroundColor Green }
}

Write-Host ""
# The account of the whole pass (#548): what was done AND what was left, by name. A sweep that
# skipped things used to end with the same reassuring line as one that skipped nothing.
if (-not $DryRun) {
    $sum = Get-DoctorFixSummary -Deleted $script:DoctorDeleted -Skipped @($script:DoctorSkipped) -HalfRemoved @($halfRemoved)
    $sumColor = if ($sum.HadSkips) { 'Yellow' } else { 'Green' }
    foreach ($l in $sum.Lines) { Write-Host $l -ForegroundColor $sumColor }
    Write-Host ""
}
if ($script:Quit) { Write-Host "Cancelado - el resto queda intacto." -ForegroundColor DarkGray }
elseif ($DryRun)  { Write-Host "DRY-RUN: nada se cambio. Quita -DryRun para ejecutarlo." -ForegroundColor Yellow }
elseif (@($script:DoctorSkipped).Count -gt 0 -or $halfRemoved.Count -gt 0) { Write-Host "Listo, con elementos omitidos (ver el resumen de arriba). Vuelve a correr sin -Fix para ver el inventario." -ForegroundColor Yellow }
else              { Write-Host "Listo. Vuelve a correr sin -Fix para ver el inventario limpio." -ForegroundColor Green }
Write-Host ""
