<#
.SYNOPSIS
    Cross-account PR workflow for /board work step 5a: push + PR with the RIGHT identity.

.DESCRIPTION
    Closes the work loop on any BI repo regardless of which account owns it:

      1. Derives owner/name from the origin remote (credentials in the URL are
         ignored, never reused) unless -Repo is given.
      2. Resolves the account FROM THE REPO OWNER: CSalcedoDataBI ->
         GITHUB_TOKEN_PERSONAL, PAL-Devs -> GITHUB_TOKEN_BUSINESS. An unmapped
         owner falls back to the personal PAT with a warning; -TokenVar overrides.
         GH_TOKEN already set in the session is deliberately IGNORED here - the
         identity must match the repo owner, not whatever ran last.
      3. Verifies the token's login has push permission on the repo (no silent
         403 later) and shows which identity is acting.
      4. Pushes the branch to an explicit clean URL through a ONE-SHOT credential
         helper: the stored remote is never rewritten and the token never appears
         on the command line, in git output, or in logs.
      5. Opens the PR with 'Closes #<n>' in the body - or, if an open PR for the
         branch already exists, just pushes to it (re-running after review-gate
         feedback is exactly this).

    Never commits or merges anything: push + PR only. The merge still goes
    through Board-ReviewGate.ps1.

.PARAMETER Issue
    One or more issue numbers the PR closes. Mandatory - board PRs always track at least
    one issue. Pass several (`-Issue 631,632`) to close a batch of small, related sub-issues
    with a SINGLE PR instead of one PR per issue (#633) - the body gets one 'Closes #<n>' line
    per issue. Accepts comma-separated strings too (`-Issue '631,632'`), the same tolerant
    parsing `-Parallel` uses in Board-Work.ps1, so a cross-process `pwsh -File` call that would
    otherwise flatten a PowerShell array into one string still works.

.PARAMETER Repo
    owner/name. Default: derived from the origin remote of the cwd.

.PARAMETER Branch
    Branch to push. Default: the currently checked-out branch.

.PARAMETER Base
    Base branch for the PR. Default: the repo's default branch.

.PARAMETER Title
    PR title. Default: the first issue's title - pass this explicitly for a batch PR closing
    more than one issue, since no single issue's title describes the whole batch.

.PARAMETER Body
    Extra body text appended after the mandatory 'Closes #<n>' line(s).

.PARAMETER Draft
    Open the PR as a draft.

.PARAMETER DryRun
    Print everything that would happen (account, identity, push, PR) and exit
    without mutating.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default: auto-resolved from the repo
    owner (see above). Set explicitly to force an account.

.PARAMETER AllowBranchMismatch
    Skip the check that the branch being pushed is the one a LIVE session registered for
    these issue(s) in THIS working copy (#547). Without it a mismatch stops the run: it means
    another session switched the branch under this one, and whatever was committed since may
    sit on the wrong branch.

.EXAMPLE
    .\New-BoardPR.ps1 -Issue 13
    .\New-BoardPR.ps1 -Issue 42 -Repo PAL-Devs/fabric-reports -Draft
    .\New-BoardPR.ps1 -Issue 13 -DryRun
    .\New-BoardPR.ps1 -Issue 631,632 -Title "Group small sequential sub-issues into one PR"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Issue,
    [string]$Repo     = "",
    [string]$Branch   = "",
    [string]$Base     = "",
    [string]$Title    = "",
    [string]$Body     = "",
    [switch]$Draft,
    [switch]$DryRun,
    [string]$TokenVar = "",
    [switch]$AllowBranchMismatch
)

$ErrorActionPreference = "Stop"

# ── Pure helpers (unit-testable; no gh/network) ───────────────────────────────
# A PR "already exists" ONLY when the read returned a row with a positive-integer number (#336). The
# old guard was `@($existing).Count -gt 0`, which counted a phantom element with a null `.number` as
# "exists" and SKIPPED `gh pr create` — the run then reported success with a blank PR number and no PR
# was created. Return the first genuine PR row, or $null. Pure.
function Get-ExistingPr {
    param($PrList)
    @($PrList) | Where-Object { $_ -and (($_.number -as [int]) -gt 0) } | Select-Object -First 1
}

# Parses -Issue the same tolerant way Board-Work.ps1's Get-ParallelQueue parses -Parallel:
# comma-split each token, keep positive integers only, dedupe, preserve first-seen order (#633).
# Order matters here - the FIRST issue drives the default -Title when none is given.
function Get-IssueNumbers {
    param($Raw)
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $out  = @()
    foreach ($tok in @($Raw)) {
        foreach ($piece in ("$tok" -split ',')) {
            $n = 0
            if ([int]::TryParse($piece.Trim(), [ref]$n) -and $n -gt 0 -and $seen.Add($n)) {
                $out += $n
            }
        }
    }
    return $out
}

# Builds the mandatory 'Closes #<n>' block - one line per issue - plus any extra -Body text (#633).
function Format-ClosesBody {
    param([int[]]$Issues, [string]$Extra = "")
    $closes = ($Issues | ForEach-Object { "Closes #$_" }) -join "`n"
    if ($Extra) { return "$closes`n`n$Extra" }
    return $closes
}

# A path in a form two spellings of the same folder compare equal in: full, forward slashes,
# no trailing separator (roots excepted), case-folded unless -CaseSensitive. Registry paths and
# `git rev-parse --show-toplevel` spell the same worktree differently (`C:\r\wt` vs `C:/r/wt`).
function ConvertTo-ComparablePath {
    param([string]$Path, [switch]$CaseSensitive)
    if (-not $Path) { return '' }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    # An 8.3 short name (`C:\Users\CRISTO~1\...`) is the same folder as its long spelling, and if the
    # two compared unequal the registry row would be skipped and a real branch mismatch missed - the
    # fail-open direction. GetFullPath expands short names on the hosts measured (pwsh 7.6, Windows
    # PowerShell 5.1), but that is an implementation detail; Get-Item hands back the on-disk spelling
    # by contract (Resolve-Path and FileSystemObject keep the short one), so an existing path is
    # canonicalised through it. A path that no longer exists has no other spelling to reconcile.
    try {
        if (Test-Path -LiteralPath $full) { $full = (Get-Item -LiteralPath $full -Force -ErrorAction Stop).FullName }
    } catch { }
    $p = $full.Replace('\', '/')
    # Trim the trailing separator, but never off a ROOT: `/` would become '' (an empty path reads as
    # "no working copy" and silently skips the check) and `C:/` would become the drive-relative `c:`.
    if ($p -ne '/' -and $p -notmatch '^[A-Za-z]:/$') { $p = $p.TrimEnd('/') }
    # Windows and macOS volumes are case-insensitive, so two spellings differing only by case are one
    # folder; a Linux filesystem is case-sensitive and folding there could merge two distinct folders.
    if (-not $CaseSensitive) { $p = $p.ToLowerInvariant() }
    return $p
}

# A registry PID as a positive int, or 0 when it is not one. `[int]$x` THROWS on "abc" or an overflow,
# and a throw inside a Where-Object filter aborts the whole run instead of skipping one bad row.
function ConvertTo-PositiveInt {
    param($Value)
    $n = 0
    if ([int]::TryParse("$Value", [ref]$n) -and $n -gt 0) { return $n }
    return 0
}

# The sessions of sessions.json whose process is still alive. A dead PID is a session that ended
# (or crashed): its entry says nothing about who holds the working copy NOW, and treating it as
# live would make the check below fire on stale rows (#547 asks that dead PIDs never count).
function Get-LiveSessionEntries {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try { $all = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return @() }
    # A row whose PID is not a positive int (hand edit, partial write) is NOT a live session: skip it
    # rather than let the cast abort the whole check.
    return @($all | Where-Object {
        $_ -and ($procId = ConvertTo-PositiveInt $_.sessionPid) -gt 0 -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)
    })
}

# #547: two agent sessions sharing one working copy can leave a commit on the wrong branch, and
# nothing said so until the PR. The session that started the issue REGISTERED the branch it was
# given; if the branch about to be pushed is a different one, someone switched it under that
# session. Returns the refusal text, or '' when there is nothing to object to. Pure over its
# inputs. Only an entry that matches on ISSUE, REPO (when both are known) and WORKING COPY counts,
# so a session working the same issue elsewhere - a worktree - never trips it.
function Get-RegisteredBranchMismatch {
    param(
        [object[]]$Entries = @(),
        [string]  $Repo = '',
        [int[]]   $Issues = @(),
        [string]  $WorkPath = '',
        [string]  $Branch = '',
        # Linux paths are case-sensitive; the caller decides (see the call site). Default: fold case.
        [switch]  $CaseSensitive
    )
    $here = ConvertTo-ComparablePath $WorkPath -CaseSensitive:$CaseSensitive
    if (-not $here -or -not $Branch) { return '' }
    $mine = @($Entries | Where-Object {
        $_ -and $_.branch -and
        (@($Issues) -contains (ConvertTo-PositiveInt $_.issue)) -and
        -not ($_.repo -and $Repo -and ("$($_.repo)" -ne $Repo)) -and
        ((ConvertTo-ComparablePath "$($_.workPath)" -CaseSensitive:$CaseSensitive) -ceq $here)
    })
    if ($mine.Count -eq 0) { return '' }
    # Several rows can name the same issue and folder (a restart under a new branch name); the
    # branch being pushed only has to be one the folder legitimately registered.
    if (@($mine | Where-Object { "$($_.branch)" -eq $Branch }).Count -gt 0) { return '' }
    $e = $mine[0]
    return "el issue #$($e.issue) se registro en la rama '$($e.branch)' de esta copia de trabajo, pero se va a empujar '$Branch'. " +
           "Otra sesion pudo cambiar la rama de esta carpeta, y lo commiteado desde entonces puede estar en la rama equivocada. " +
           "Revisa con 'git log' y vuelve a '$($e.branch)' (git checkout $($e.branch), o pasa -Branch $($e.branch)); " +
           "-AllowBranchMismatch lo omite a proposito."
}

# Dot-source guard: tests set $env:ABIOS_NEWBOARDPR_DOTSOURCE to load the pure helper only.
if ($env:ABIOS_NEWBOARDPR_DOTSOURCE) { return }

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# gh must fail closed on the "is there already an open PR?" read (#336/#303): a swallowed failure
# used to be indistinguishable from "no PR" and took the silent-skip path above.
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

# The single resolver for owner/name from this clone's origin (#281, #392). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# -- 1. Repo: -Repo or origin (strip any embedded credential - never reuse it) --
if (-not $Repo) { $Repo = Get-RepoFromOrigin }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo debe ser owner/name (recibi '$Repo')." }
$owner = ($Repo -split '/')[0]

# -- 1b. Is the branch about to be pushed the one this working copy's session registered? (#547)
# Local-only (no gh, no token), so it runs BEFORE the identity work and fails fast. It can only
# ADD a refusal; -AllowBranchMismatch restores the old behaviour on purpose.
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
$pushBranch = if ($Branch) { $Branch } else { "$(git rev-parse --abbrev-ref HEAD 2>$null)".Trim() }
$stateDir   = Get-AbiosStateDir -NoCreate
if ($stateDir -and $pushBranch -and $pushBranch -ne 'HEAD') {
    $mismatch = Get-RegisteredBranchMismatch `
        -Entries  (Get-LiveSessionEntries (Join-Path $stateDir 'sessions.json')) `
        -Repo     $Repo `
        -Issues   @(Get-IssueNumbers $Issue) `
        -WorkPath ("$(git rev-parse --show-toplevel 2>$null)".Trim()) `
        -CaseSensitive:([bool]$IsLinux) `
        -Branch   $pushBranch
    if ($mismatch -and -not $AllowBranchMismatch) { throw $mismatch }
    if ($mismatch) { Write-Host "AVISO: $mismatch" -ForegroundColor Yellow }
}

# -- 2. Identity: the OWNER's account, or the AGENT's inside a braked run (#550) ----
# This is the script a braked run reaches for when it pushes its branch and opens the PR, so it is
# the place where the identity actually has to change. Resolve-GhTokenVar owns the decision; the
# owner->variable map used to be copied here (and in three other scripts), which is how four copies
# of one rule drift apart.
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT

# ONE path, override included. The first cut branched on -TokenVar and skipped the armed check on
# that branch, so a braked run got the owner's admin identity back by adding one flag to its own
# invocation (review round 2). An override is now something the resolver JUDGES, not something that
# routes around it.
$ctx = Get-GhTokenForContext -StartDir (Get-Location).Path -Owner $owner -ExplicitVar $TokenVar
$token    = $ctx.token
$TokenVar = $ctx.var
if ($ctx.armed) {
    Write-Host "  Identidad de agente: $TokenVar (run frenado - sin admin, GitHub le niega main)." -ForegroundColor Cyan
}
# On purpose: override any session GH_TOKEN - identity must match the context resolved above.
$env:GH_TOKEN = $token

# -- 3. Identity + push permission ---------------------------------------------
$login = "$(gh api user --jq .login 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $login) { throw "El token de $TokenVar no autentica contra la API." }
$repoInfo = gh api "repos/$Repo" 2>$null | ConvertFrom-Json
if (-not $repoInfo) { throw "'$login' no ve el repo $Repo (no existe o sin acceso). Cuenta equivocada?" }
if (-not $repoInfo.permissions.push) {
    throw "'$login' NO tiene permiso de push en $Repo. Usa la cuenta correcta (-TokenVar) o pide acceso - el flujo por fork queda fuera de este script."
}
if (-not $Base) { $Base = $repoInfo.default_branch }

# -- 4. Branch ------------------------------------------------------------------
if (-not $Branch) { $Branch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim() }
if (-not $Branch -or $Branch -eq 'HEAD') { throw "No pude resolver la rama actual - usa -Branch." }
if ($Branch -eq $Base) { throw "Estas en '$Base' (la base). Trabaja el issue en su rama issue-<num>-<slug> - nunca PR desde la base a si misma." }

# -- 5. Issue(s) -> title / body -------------------------------------------------
$issueNums = @(Get-IssueNumbers $Issue)
if ($issueNums.Count -eq 0) { throw "-Issue no trajo ningun numero de issue valido (recibi '$($Issue -join ',')')." }

$issues = @()
foreach ($n in $issueNums) {
    $one = gh api "repos/$Repo/issues/$n" 2>$null | ConvertFrom-Json
    if (-not $one) { throw "Issue #$n no existe en $Repo." }
    if ($one.state -ne 'open') { Write-Host "AVISO: issue #$n esta '$($one.state)' - el PR igual lo referencia." -ForegroundColor Yellow }
    $issues += $one
}
if (-not $Title) { $Title = $issues[0].title }
$prBody = Format-ClosesBody -Issues $issueNums -Extra $Body

# -- Existing open PR for this branch? (re-run = iterate on it) ------------------
# Fail closed (Invoke-Gh -Json) then require a positive-integer number: a phantom/null-number row is
# NOT an existing PR, so the create path runs instead of silently skipping (#336).
$existing   = @(Invoke-Gh -GhArgs @('pr','list','--repo',$Repo,'--head',$Branch,'--state','open','--json','number,url') `
                          -What "buscar un PR abierto para la rama $Branch" -Json)
$existingPr = Get-ExistingPr $existing

Write-Host "=== Cross-account PR  $Repo ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Identidad : $login  (via $TokenVar)"
Write-Host "  Rama      : $Branch -> $Base"
foreach ($one in $issues) { Write-Host ("  Issue     : #{0} {1}" -f $one.number, $one.title) }
if ($existingPr) {
    Write-Host "  PR        : #$($existingPr.number) ya abierto - solo push (iteracion)" -ForegroundColor Yellow
} else {
    Write-Host "  PR        : nuevo$(if ($Draft) { ' (draft)' })  titulo: $Title"
}
Write-Host ""

if ($DryRun) {
    Write-Host "DRY-RUN: no se empuja ni se crea nada." -ForegroundColor Yellow
    exit 0
}

# -- 6. Push via one-shot credential helper (remote never rewritten) -------------
# The token travels ONLY as an env var read by the helper inside git's sh -
# never on the command line, never in the stored remote, never in output.
$env:ABIOS_PR_TOKEN = $token
try {
    git -c credential.helper= `
        -c 'credential.helper=!f(){ echo username=x-access-token; echo password=$ABIOS_PR_TOKEN; };f' `
        push "https://github.com/$Repo.git" "refs/heads/${Branch}:refs/heads/${Branch}"
    if ($LASTEXITCODE -ne 0) { throw "git push fallo (exit $LASTEXITCODE)." }
} finally {
    Remove-Item Env:ABIOS_PR_TOKEN -ErrorAction SilentlyContinue
}
Write-Host "OK  rama '$Branch' empujada a $Repo como $login" -ForegroundColor Green

# -- 7. PR: reuse the open one, or create ----------------------------------------
if ($existingPr) {
    $prNum = $existingPr.number
    $prUrl = $existingPr.url
    Write-Host "OK  PR #$prNum ya existia - commits nuevos empujados" -ForegroundColor Green
} else {
    $ghArgs = @('pr','create','--repo',$Repo,'--head',$Branch,'--base',$Base,'--title',$Title,'--body',$prBody)
    if ($Draft) { $ghArgs += '--draft' }
    $prUrl = (gh @ghArgs).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $prUrl) { throw "gh pr create fallo." }
    $prNum = [int]($prUrl -replace '^.*/','')
    Write-Host "OK  PR #$prNum creado: $prUrl" -ForegroundColor Green
}

Write-Host ""
Write-Host "Siguiente paso (gate obligatorio antes de mergear):" -ForegroundColor Yellow
Write-Host "  corre el review gate sobre $Repo PR #$prNum"
Write-Host ""
Write-Host "PR: $prUrl" -ForegroundColor Cyan
