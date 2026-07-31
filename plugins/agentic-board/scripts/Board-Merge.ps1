<#
.SYNOPSIS
    Merge a gated PR for /board work step 5d - handling the pr-before-merge ruleset.

.DESCRIPTION
    The work flow installs a `pr-before-merge` ruleset (Board-ReviewGate.ps1
    -InstallRuleset). Once active, GitHub marks PRs as mergeable_state=blocked
    and `gh pr merge` refuses to merge without `--admin` - even though the
    ruleset grants repo admins an always-on bypass and requires 0 approving
    reviews. So the gate says "safe to merge" but a raw `gh pr merge` then
    fails. This helper closes that gap:

      1. Resolves owner/name from origin (embedded creds ignored) unless -Repo.
      2. Resolves the account FROM THE REPO OWNER (CSalcedoDataBI -> personal,
         PAL-Devs -> business; -TokenVar overrides), like New-BoardPR.ps1, and
         checks whether that identity is a repo admin (bypass candidate).
      3. Tries a normal `gh pr merge`. If it succeeds, done.
      4. If it fails BECAUSE the branch policy blocks it AND the identity is a
         repo admin (has bypass), retries with `--admin` and says so honestly.
      5. If the identity has no bypass, prints the block clearly (exit 1)
         instead of a raw gh error - no silent stumble.

    Call it AFTER Board-ReviewGate.ps1 exits 0. It never bypasses the gate
    (CI + review); it only exercises the admin bypass the ruleset itself grants.

.PARAMETER PR
    Pull request number to merge. Mandatory.

.PARAMETER Repo
    owner/name. Default: derived from the origin remote of the cwd.

.PARAMETER Method
    Merge method: squash (default), merge, or rebase.

.PARAMETER NoDeleteBranch
    Keep the head branch after merge (default deletes it).

.PARAMETER DryRun
    Print the merge command that would run (and whether an admin bypass is
    likely needed) without merging.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Default: auto-resolved from the repo
    owner. Set explicitly to force an account.

.EXAMPLE
    .\Board-Merge.ps1 -PR 113
    .\Board-Merge.ps1 -PR 42 -Repo PAL-Devs/fabric-reports -Method merge
    .\Board-Merge.ps1 -PR 113 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$PR,
    [string]$Repo = "",
    [ValidateSet('squash','merge','rebase')][string]$Method = 'squash',
    [switch]$NoDeleteBranch,
    [switch]$DryRun,
    [string]$TokenVar = ""
)

$ErrorActionPreference = "Stop"

# ── Brake check (#516) ──────────────────────────────────────────────────────────
# Defense in depth. The PreToolUse guard already refuses `Board-Merge.ps1` inside a brake-armed
# worktree, but that guard only exists where the plugin's hooks are installed. This check lives in
# the merge path itself, so the refusal survives a session with no hooks, a direct pwsh call, or a
# future launcher that forgets to wire them. -DryRun is exempt: it mutates nothing.
#
# DEFINED here, CALLED after the repo and token are resolved (see the call site below). Running it
# inline at this point read `$Repo` while it was still the empty default and `$env:GH_TOKEN` before
# it was set, so every PR fact came back blank and a legitimately ordered run was refused for
# "conditions unmet" that were never actually read.
function Invoke-BrakeMergeCheck {
# CAPTURE THE PARAMETERS FIRST, before a single dot-source runs (#536). Dot-sourcing executes the
# sourced script's param() block IN THIS SCOPE, and Board-ReviewGate.ps1 declares `[int]$PR = 0` -
# so halfway down this function `$PR` silently became 0 and `gh pr checks 0` returned nothing. The
# tests condition was therefore never satisfiable and end-to-end mode could refuse but never
# allow. Reading the parameter once, up here, is the whole fix; the rule is "capture before you
# dot-source", not "remember which script clobbers which name".
$prNumber = [int]$PR
if (-not $DryRun) {
    $brakeGuard = Join-Path $PSScriptRoot 'Brake-Guard.ps1'
    if (Test-Path $brakeGuard) {
        $prevB = $env:ABIOS_BRAKEGUARD_DOTSOURCE
        $env:ABIOS_BRAKEGUARD_DOTSOURCE = '1'
        . $brakeGuard
        $env:ABIOS_BRAKEGUARD_DOTSOURCE = $prevB
        $brakeMarker = Read-BrakeMarker -StartDir (Get-Location).Path
        if ($brakeMarker -and (@($brakeMarker.irreversible) -contains 'merge')) {
            $forWhat = if ($brakeMarker.issue -gt 0) { " para el issue #$($brakeMarker.issue)" } else { "" }

            # END-TO-END (#530). The brake is no longer all-or-nothing: a run the human ORDERED to
            # finish may close CODE work that carries a real review and recorded tests for THIS
            # commit. Every one of those is established here, at merge time, because this is the
            # first moment the facts exist - the marker was written before a line of code did.
            $verdict = $null
            try {
                $prevE = $env:ABIOS_ENDTOEND_DOTSOURCE
                $env:ABIOS_ENDTOEND_DOTSOURCE = '1'
                . (Join-Path $PSScriptRoot 'Expert-EndToEnd.ps1')
                $env:ABIOS_ENDTOEND_DOTSOURCE = $prevE

                # Diff against the PR's OWN base, not the repo default. A PR targeting a release or
                # feature branch would otherwise be compared to main, quietly omitting files and
                # letting a report change read as code.
                $prMeta  = gh pr view $prNumber --repo $Repo --json headRefOid,baseRefName 2>$null | ConvertFrom-Json
                $baseRef = if ($prMeta.baseRefName) { "origin/$($prMeta.baseRefName)" } else { '' }
                if (-not $baseRef) {
                    $baseRef = git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
                    if (-not $baseRef) { $baseRef = 'origin/main' }
                }
                $changed = @(git diff --name-only "$baseRef...HEAD" 2>$null | Where-Object { "$_".Trim() })

                # Classify with THIS project's policy, not the built-in defaults: a contract that
                # declares extra visual patterns (a site where the posts are the product) would
                # otherwise be ignored exactly where it matters.
                $prevC2 = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
                $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
                . (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
                $env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC2
                $contract = Read-ExpertContract
                $wcPolicy = Get-EffectiveWorkClassPolicy -Contract $contract
                $wc = Get-WorkClass -ChangedPaths $changed -Policy $wcPolicy

                # Whether automated tests are REQUIRED is the contract's call, not this run's
                # (#536). It was never passed, so it defaulted to $true and a project that
                # honestly declares no automated suite could never close anything. Absent or
                # malformed dod.tests still means required - the safe direction.
                # Get-TestsRequired, not [bool]$contract.dod['tests']: a quoted "false" would cast
                # to $true, the same trap already closed for the marker's endToEnd field.
                $testsRequired = Get-TestsRequired -Contract $contract

                # REVIEW evidence: reuse the gate's own strict parser rather than a looser copy.
                # Matching "contains the marker AND contains the sha" anywhere in a body let quoted
                # text, a checklist note or a stale comment satisfy a merge condition. The gate's
                # parser requires the marker to be BOUND as `sha=<head>`.
                $headSha = "$($prMeta.headRefOid)".Trim()
                if (-not $headSha) { throw "no pude leer el commit actual del PR #$prNumber" }
                $bodies = @()
                $cj = gh pr view $prNumber --repo $Repo --json comments 2>$null
                if ($cj) { $bodies = @(($cj | ConvertFrom-Json).comments | ForEach-Object { "$($_.body)" }) }

                $prevG = $env:ABIOS_REVIEWGATE_DOTSOURCE
                $env:ABIOS_REVIEWGATE_DOTSOURCE = '1'
                . (Join-Path $PSScriptRoot 'Board-ReviewGate.ps1') -Repo $Repo
                $env:ABIOS_REVIEWGATE_DOTSOURCE = $prevG
                $reviewed = [bool](Get-ReviewEvidence -CommentBodies $bodies -HeadSha $headSha).reviewed

                # TEST evidence: taken from CI, NOT from a block the run wrote about itself.
                # An [abios-evidence] comment is the run's own account of its testing - useful to
                # read, worthless as proof, and this is the one place the difference decides a
                # merge. CI ran the suite on this commit independently; that is the claim that
                # cannot be self-issued. Green means: checks exist and none is failing or pending.
                # $prNumber, never $PR: by this line the review-gate dot-source above has reset
                # $PR to 0 (#536). The verdict itself lives in Test-CiChecksPassed so it can be
                # tested without the network.
                $chk = gh pr checks $prNumber --repo $Repo --json name,bucket 2>$null
                $tested = Test-CiChecksPassed -ChecksJson "$chk"

                $verdict = Test-EndToEndAllowed -Ordered ([bool]$brakeMarker.endToEnd) `
                             -WorkClass $wc.class -ReviewedHead $reviewed -TestsRecorded $tested `
                             -TestsRequired $testsRequired
            } catch {
                # Could not establish the facts -> no permission. "I could not check" is not a yes.
                $verdict = @{ allowed = $false; missing = @("no pude verificar las condiciones ($_)")
                              reason  = "no pude verificar las condiciones ($_)" }
            }

            if ($verdict.allowed) {
                # Remembered so the merge itself can be pinned to this exact commit (see $mergeArgs).
                $script:E2eHeadSha = $headSha
                Write-Host ""
                Write-Host (Format-EndToEndVerdict -Verdict $verdict) -ForegroundColor Green
                Write-Host "  (Freno armado, pero el dueno ordeno llevarlo hasta el final y se cumplen las condiciones.)" -ForegroundColor DarkGray
                Write-Host ("  El cierre queda atado al commit {0} - si llega uno nuevo, no se mergea." -f $headSha.Substring(0,7)) -ForegroundColor DarkGray
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "FRENO ACTIVO: este worktree pertenece a un run autonomo con freno armado$forWhat." -ForegroundColor Red
                Write-Host (Format-EndToEndVerdict -Verdict $verdict) -ForegroundColor Yellow
                Write-Host "  Marcador: $($brakeMarker.path)" -ForegroundColor DarkGray
                Write-Host "  (Si de verdad quieres mergear a mano, borra ese archivo primero - a conciencia.)" -ForegroundColor DarkGray
                Write-Host ""
                exit 1
            }
        }
    }
}
}

# The single resolver for owner/name from this clone's origin (#281, #392). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# After a successful merge, gh's --delete-branch removes the REMOTE branch, but its LOCAL delete is
# best-effort: it silently no-ops when the branch is checked out (here, or in another worktree) or
# the merge came from the UI/another machine. That silent miss is how merged branches pile up (#302
# finding #2). Verify it, and when the local branch survived, say so and point at the single-session
# teardown (cerrar-ciclo) that finishes the job - never report a cleanup that did not happen.
function Show-LocalBranchCleanupHint {
    param([string]$Branch)
    if (-not $Branch) { return }
    git rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  NOTA: la rama local '{0}' sigue aqui - --delete-branch no la borra si esta checkouteada." -f $Branch) -ForegroundColor DarkYellow
        Write-Host  "        Cierrala con:  Board-Work.ps1 -CloseLoop   (o /board cerrar-ciclo)" -ForegroundColor DarkGray
    }
}

# -- 1. Repo: -Repo or origin (strip any embedded credential - never reuse it) --
if (-not $Repo) { $Repo = Get-RepoFromOrigin }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "-Repo debe ser owner/name (recibi '$Repo')." }
$owner = ($Repo -split '/')[0]

# -- 2. Account FROM THE OWNER (same mapping as New-BoardPR.ps1) ----------------
$ownerVarMap = @{
    'CSalcedoDataBI' = 'GITHUB_TOKEN_PERSONAL'
    'PAL-Devs'       = 'GITHUB_TOKEN_BUSINESS'
}
if (-not $TokenVar) {
    if ($ownerVarMap.ContainsKey($owner)) {
        $TokenVar = $ownerVarMap[$owner]
    } else {
        $TokenVar = 'GITHUB_TOKEN_PERSONAL'
        Write-Host "AVISO: owner '$owner' no esta mapeado a una cuenta - uso la personal por defecto (-TokenVar para forzar otra)." -ForegroundColor Yellow
    }
}
$token = [System.Environment]::GetEnvironmentVariable($TokenVar, 'User')
if ([string]::IsNullOrWhiteSpace($token)) { throw "$TokenVar no esta en el entorno USER de Windows." }
# On purpose: identity must match the repo owner, not whatever ran last.
$env:GH_TOKEN = $token

# NOW the brake check can read the PR: $Repo is resolved and the token is in place. Defined far
# above, called here on purpose - it refuses (exit 1) before anything is merged, and every fact it
# weighs is one it could actually read.
Invoke-BrakeMergeCheck

# -- 3. Identity + admin (bypass candidate) ------------------------------------
$login = "$(gh api user --jq .login 2>$null)".Trim()
if ($LASTEXITCODE -ne 0 -or -not $login) { throw "El token de $TokenVar no autentica contra la API." }
$repoInfo = gh api "repos/$Repo" 2>$null | ConvertFrom-Json
if (-not $repoInfo) { throw "'$login' no ve el repo $Repo (no existe o sin acceso)." }
$isAdmin = [bool]$repoInfo.permissions.admin

# -- 4. PR state ---------------------------------------------------------------
$prInfo = gh pr view $PR --repo $Repo --json state,title,mergedAt,headRefName 2>$null | ConvertFrom-Json
if (-not $prInfo) { throw "PR #$PR no existe en $Repo." }
$headBranch = [string]$prInfo.headRefName
if ($prInfo.state -eq 'MERGED' -or $prInfo.mergedAt) {
    Write-Host "PR #$PR ya esta MERGED - nada que hacer." -ForegroundColor Green
    exit 0
}
if ($prInfo.state -ne 'OPEN') { throw "PR #$PR esta '$($prInfo.state)' (no OPEN) - no se puede mergear." }

$mergeArgs = @('pr','merge',"$PR",'--repo',$Repo,"--$Method")
if (-not $NoDeleteBranch) { $mergeArgs += '--delete-branch' }

# Bind the merge to the exact commit the four conditions were established against (#530). Between
# reading the class, the review and the checks and actually merging, a push to the branch would
# otherwise slip a NEW commit through on the strength of an older one's evidence - the precise
# failure this control exists to stop, just moved a few seconds later. Only for the autonomous
# path: a human running this deliberately does not need the interlock.
if ($script:E2eHeadSha) {
    $mergeArgs += @('--match-head-commit', $script:E2eHeadSha)
}

Write-Host "=== Board-Merge  $Repo  PR #$PR ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Identidad : $login  (via $TokenVar)$(if ($isAdmin) { ' [admin: bypass disponible]' })"
Write-Host "  Merge     : --$Method$(if (-not $NoDeleteBranch) { ' --delete-branch' })  '$($prInfo.title)'"
Write-Host ""

if ($DryRun) {
    Write-Host "DRY-RUN: gh $($mergeArgs -join ' ')" -ForegroundColor Yellow
    Write-Host "         (si el ruleset lo bloquea y eres admin, reintentaria con --admin)" -ForegroundColor DarkGray
    exit 0
}

# -- 5. Try a normal merge first ------------------------------------------------
$out  = (& gh @mergeArgs 2>&1 | Out-String)
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host "OK  PR #$PR mergeado (--$Method)." -ForegroundColor Green
    if (-not $NoDeleteBranch) { Show-LocalBranchCleanupHint $headBranch }
    exit 0
}

# -- 6. Blocked by branch policy? Retry with the admin bypass the ruleset grants.
$blocked = $out -match '(?i)not mergeable|base branch policy|protected|prohibits|required'
if (-not $blocked) {
    Write-Host "FAIL merge de #${PR}:" -ForegroundColor Red
    Write-Host ($out.Trim()) -ForegroundColor Red
    exit 1
}

if (-not $isAdmin) {
    Write-Host "BLOQUEADO: el branch policy de $Repo impide el merge y '$login' NO es admin (sin bypass)." -ForegroundColor Red
    Write-Host "Pide a un admin que lo mergee, o ajusta el ruleset. Detalle:" -ForegroundColor Yellow
    Write-Host ($out.Trim()) -ForegroundColor DarkGray
    exit 1
}

Write-Host "AVISO: el ruleset marca el PR como blocked; uso el bypass de admin (--admin) que el propio" -ForegroundColor Yellow
Write-Host "       ruleset otorga a los admins. El gate (CI + review) ya paso; esto solo salta el estado" -ForegroundColor Yellow
Write-Host "       'blocked' que gh exige confirmar." -ForegroundColor Yellow
$out2  = (& gh @($mergeArgs + '--admin') 2>&1 | Out-String)
$code2 = $LASTEXITCODE
if ($code2 -eq 0) {
    Write-Host "OK  PR #$PR mergeado con bypass de admin (--$Method --admin)." -ForegroundColor Green
    if (-not $NoDeleteBranch) { Show-LocalBranchCleanupHint $headBranch }
    exit 0
}
Write-Host "FAIL ni con --admin se pudo mergear #${PR}:" -ForegroundColor Red
Write-Host ($out2.Trim()) -ForegroundColor Red
exit 1
