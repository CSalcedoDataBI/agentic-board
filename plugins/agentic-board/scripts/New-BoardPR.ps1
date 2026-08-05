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
    Issue number the PR closes. Mandatory - board PRs always track an issue.

.PARAMETER Repo
    owner/name. Default: derived from the origin remote of the cwd.

.PARAMETER Branch
    Branch to push. Default: the currently checked-out branch.

.PARAMETER Base
    Base branch for the PR. Default: the repo's default branch.

.PARAMETER Title
    PR title. Default: the issue's title.

.PARAMETER Body
    Extra body text appended after the mandatory 'Closes #<n>' line.

.PARAMETER Draft
    Open the PR as a draft.

.PARAMETER DryRun
    Print everything that would happen (account, identity, push, PR) and exit
    without mutating.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default: auto-resolved from the repo
    owner (see above). Set explicitly to force an account.

.EXAMPLE
    .\New-BoardPR.ps1 -Issue 13
    .\New-BoardPR.ps1 -Issue 42 -Repo PAL-Devs/fabric-reports -Draft
    .\New-BoardPR.ps1 -Issue 13 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Issue,
    [string]$Repo     = "",
    [string]$Branch   = "",
    [string]$Base     = "",
    [string]$Title    = "",
    [string]$Body     = "",
    [switch]$Draft,
    [switch]$DryRun,
    [string]$TokenVar = ""
)

$ErrorActionPreference = "Stop"

# ── Pure helper (unit-testable; no gh/network) ────────────────────────────────
# A PR "already exists" ONLY when the read returned a row with a positive-integer number (#336). The
# old guard was `@($existing).Count -gt 0`, which counted a phantom element with a null `.number` as
# "exists" and SKIPPED `gh pr create` — the run then reported success with a blank PR number and no PR
# was created. Return the first genuine PR row, or $null. Pure.
function Get-ExistingPr {
    param($PrList)
    @($PrList) | Where-Object { $_ -and (($_.number -as [int]) -gt 0) } | Select-Object -First 1
}

# Dot-source guard: tests set $env:ABIOS_NEWBOARDPR_DOTSOURCE to load the pure helper only.
if ($env:ABIOS_NEWBOARDPR_DOTSOURCE) { return }

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

# -- 5. Issue -> title / body ----------------------------------------------------
$iss = gh api "repos/$Repo/issues/$Issue" 2>$null | ConvertFrom-Json
if (-not $iss) { throw "Issue #$Issue no existe en $Repo." }
if ($iss.state -ne 'open') { Write-Host "AVISO: issue #$Issue esta '$($iss.state)' - el PR igual lo referencia." -ForegroundColor Yellow }
if (-not $Title) { $Title = $iss.title }
$prBody = "Closes #$Issue"
if ($Body) { $prBody = "$prBody`n`n$Body" }

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
Write-Host "  Issue     : #$Issue $($iss.title)"
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
Write-Host "  Board-ReviewGate.ps1 -Repo $Repo -PR $prNum -TokenVar $TokenVar"
Write-Host ""
Write-Host "PR: $prUrl" -ForegroundColor Cyan
