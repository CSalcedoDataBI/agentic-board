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

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

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
# A TRAP FOR WHOEVER RESTORES THE GATE HERE (#536 -> #541), recorded because it cost real
# debugging and is invisible in a normal reading: this function dot-sources other scripts, and
# dot-sourcing runs THEIR param() block IN THIS SCOPE. `Board-ReviewGate.ps1` declares
# `[int]$PR = 0`, so the moment it is sourced, `$PR` here becomes 0. The end-to-end gate that used
# to live below read `gh pr checks $PR` afterwards, asked CI about PR number 0, got nothing, and
# concluded "no tests ran" for every run alive. Capture the parameters into local names BEFORE the
# first dot-source; do not rely on remembering which script clobbers which name.
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

            # THE ARMED RUN DOES NOT MERGE, ordered or not (#541).
            #
            # This block used to weigh four conditions and, when all held, let a run the owner had
            # ORDERED to finish close its own PR. That allowance is withdrawn: review found the
            # gate could not defend itself once it was reachable. `cd` out of the worktree and the
            # marker lookup above finds nothing, so this whole check is skipped -- the two halves
            # of the control disagreed about which directory the run was in. And the review
            # condition was satisfied by a PR comment the run can post itself.
            #
            # Leaving the allowance here "as defense in depth" would be the same self-deception:
            # the hook is not a guarantee, so a command string it misses would arrive at a script
            # that still says yes. The decision function and its tests live on in
            # Expert-EndToEnd.ps1, ready for #541 to give them an armed context they can trust and
            # evidence the subject cannot mint.
            #
            # A HUMAN who wants this merge deletes the marker first, deliberately. That is the
            # documented path and the message below says so.
            Write-Host ""
            Write-Host "FRENO ACTIVO: este worktree pertenece a un run autonomo con freno armado$forWhat." -ForegroundColor Red
            if ($brakeMarker.endToEnd) {
                Write-Host "PUNTA A PUNTA: la orden esta REGISTRADA pero todavia no se ejecuta." -ForegroundColor Yellow
                Write-Host "  El mecanismo que la honraba tenia dos agujeros que no podia defender (#541)," -ForegroundColor Yellow
                Write-Host "  asi que ninguna ruta de merge esta abierta para ningun run." -ForegroundColor Yellow
            } else {
                Write-Host "Deja el PR listo y con el gate en verde; el cierre lo hace una persona." -ForegroundColor Yellow
            }
            Write-Host "  Marcador: $($brakeMarker.path)" -ForegroundColor DarkGray
            Write-Host "  (Si de verdad quieres mergear a mano, borra ese archivo primero - a conciencia.)" -ForegroundColor DarkGray
            Write-Host ""
            exit 1
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
# One map, not four copies (#550): Resolve-GhTokenVar owns owner -> variable.
$prevT = $env:ABIOS_TOKENVAR_DOTSOURCE
$env:ABIOS_TOKENVAR_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Resolve-GhTokenVar.ps1')
$env:ABIOS_TOKENVAR_DOTSOURCE = $prevT
if (-not $TokenVar) { $TokenVar = Get-OwnerTokenVar -Owner $owner }
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
