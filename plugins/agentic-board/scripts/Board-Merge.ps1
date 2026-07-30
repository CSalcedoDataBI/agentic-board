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
            Write-Host ""
            Write-Host "FRENO ACTIVO: este worktree pertenece a un run autonomo con freno armado$forWhat." -ForegroundColor Red
            Write-Host "  El merge es irreversible segun el contrato de este run, asi que NO se ejecuta." -ForegroundColor Red
            Write-Host "  Deja el PR abierto y con el gate en verde; el merge lo hace una persona." -ForegroundColor DarkGray
            Write-Host "  Marcador: $($brakeMarker.path)" -ForegroundColor DarkGray
            Write-Host "  (Si de verdad quieres mergear a mano, borra ese archivo primero - a conciencia.)" -ForegroundColor DarkGray
            Write-Host ""
            exit 1
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
