<#
.SYNOPSIS
    Review gate for /board work step 5: no PR merges blind.

.DESCRIPTION
    GitHub flow says merge only AFTER review/approval. This script is the
    deterministic gate the work flow runs between "PR opened" and "merge":

      1. Requests a GitHub Copilot code review (best-effort: if the account
         has no Copilot code review, it warns and continues - the agent must
         then do an explicit self-review of `gh pr diff`). It REMEMBERS, per
         account, when Copilot answered "no quota / unavailable": the next PR
         skips the request AND the wait and routes straight to self-review,
         until a cooldown (-CopilotCooldownDays) expires or -EnableCopilot is
         passed. So a quota-blocked account is not re-asked on every PR (#367).
      2. If the PR touches any *.tmdl (a PBIP semantic model), runs the two
         model-quality gates and BLOCKS on either (M3.3):
           - TMDL diff review (Tmdl-DiffReview.ps1 -FailOnBreaking): a BREAKING
             schema change blocks the merge.
           - Best Practice Analyzer (Bpa-GateReview.ps1 -FailOn error): an
             error-severity BPA violation blocks the merge.
         Both degrade safely: no model, no BPA rules file, or no Tabular Editor
         is a WARN + skip, never a block - a merge is only ever stopped by an
         actual finding. A non-BI repo never triggers either.
      3. Waits for CI checks on the PR (gh pr checks --watch). "No checks
         configured" counts as pass, with a note.
      4. Waits (up to -TimeoutMinutes) for the requested review to arrive,
         then reports: review decision, every review with author/state/body,
         and unresolved review-thread count.
      5. Verdict via exit code:
           0 -> gate PASSED (checks ok, no CHANGES_REQUESTED, no unresolved
                threads, no TMDL-breaking / BPA-error findings, AND somebody
                actually reviewed)
           1 -> gate BLOCKED (address the printed feedback, push, re-run)
           2 -> gate UNREVIEWED (#510): nothing is wrong, but nobody looked.
                Distinct from 0 on purpose - `claude-review` reported a passing
                check having left zero reviews, and a caller reading only the
                exit code could not tell "reviewed, found nothing" from "the
                reviewer never spoke". Anything testing `-eq 0` fails closed.
                Clear it by reviewing for real (-RecordReview registers an
                external review) or, when a review buys nothing, -AllowUnreviewed.

    -InstallRuleset (once per repo, optional): installs a repository ruleset
    that requires a PR before merging into the default branch. Repo admins
    keep a bypass so tooling still works - the ruleset protects against
    accidental direct pushes; the gate itself is enforced by the work flow.

.PARAMETER Repo
    owner/name of the repository. Mandatory.

.PARAMETER PR
    Pull request number to gate. Mandatory unless -InstallRuleset.

.PARAMETER InstallRuleset
    Install the require-PR ruleset on the repo's default branch (idempotent).

.PARAMETER TimeoutMinutes
    Max minutes to wait for the requested review. Default 6.

.PARAMETER MaxLines
    Small-PR guard: warn when additions+deletions exceed this. Default 600.

.PARAMETER MaxFiles
    Small-PR guard: warn when changed files exceed this. Default 20.

.PARAMETER CopilotCooldownDays
    How long to remember "this account has no Copilot" before trying again. Default 7. When the
    gate sees Copilot answer "no quota / unavailable", it marks the owner for this many days; every
    PR in that window skips the Copilot request + wait and goes straight to self-review (#367).

.PARAMETER EnableCopilot
    Forget the Copilot-unavailable marker for this repo's owner and request Copilot again this run
    (use when Copilot access is back before the cooldown expires).

.PARAMETER AllowUnreviewed
    Pass a PR that nobody reviewed (exit 0 instead of 2). For changes where a review buys nothing -
    a typo in a comment, a regenerated file. It is the deliberate exception, not the way past the
    gate: it prints that nobody looked at the code.

.PARAMETER RecordReview
    Register an external review on the PR (with -Reviewer and -Summary) so the gate counts it. This
    is how a reviewer with no GitHub identity - second-opinion / Codex, or a careful human read -
    stops being invisible to a gate that can otherwise only see GitHub review objects.

.PARAMETER Reviewer
    Who performed the external review (e.g. 'codex/gpt-5.5'). Used with -RecordReview.

.PARAMETER Summary
    What the external review found. Used with -RecordReview.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Board-ReviewGate.ps1 -Repo CSalcedoDataBI/agentic-board -PR 50
    .\Board-ReviewGate.ps1 -Repo CSalcedoDataBI/agentic-board -InstallRuleset
    .\Board-ReviewGate.ps1 -Repo CSalcedoDataBI/agentic-board -PR 50 -EnableCopilot
    .\Board-ReviewGate.ps1 -Repo CSalcedoDataBI/agentic-board -PR 50 -RecordReview -Reviewer 'codex/gpt-5.5' -Summary '4 rondas, 12 hallazgos, todos corregidos'
    .\Board-ReviewGate.ps1 -Repo CSalcedoDataBI/agentic-board -PR 50 -AllowUnreviewed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [int]   $PR = 0,
    [switch]$InstallRuleset,
    [int]   $TimeoutMinutes = 6,
    [int]   $MaxLines = 600,
    [int]   $MaxFiles = 20,
    # Days to remember "this account has no Copilot" before the gate tries it again (#367).
    [int]   $CopilotCooldownDays = 7,
    # Forget the Copilot-unavailable marker for this repo's owner and try Copilot again now.
    [switch]$EnableCopilot,
    # Accept a PR that nobody reviewed. Deliberate opt-out for the cases where a review buys
    # nothing (a typo in a comment, a generated file). Exists so the honest verdict below can be
    # the DEFAULT without stalling trivial work - never as the routine way past the gate.
    [switch]$AllowUnreviewed,
    # Record an external review (second-opinion / Codex / a human read) as a PR comment the gate
    # will recognise. This is how a reviewer with no GitHub identity gets counted (#510).
    [switch]$RecordReview,
    [string]$Reviewer = "external",
    [string]$Summary  = "",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ── Pure helper (unit-testable; no gh/network) ────────────────────────────────
# Foreign-commit detection (#309). GitHub's commits/{sha}/pulls lists every PR that contains a
# commit, so a commit GitHub associates with a DIFFERENT PR is provably not this issue's work — the
# #294 contamination shape, which the "PR grande" warning could not tell apart from a legitimately
# large PR. Given each commit's associated PR numbers, return the commits whose association is
# another PR. Warn-only: the caller must NOT let this change the verdict (the base resolution is
# best-effort, and a contaminating commit with no PR of its own is invisible to this signal). Pure.
function Find-ForeignCommits {
    param(
        [int]$SelfPr,
        $Commits            # array of { Sha; Pulls (int[]) }
    )
    $foreign = @()
    foreach ($c in @($Commits)) {
        $others = @($c.Pulls | Where-Object { ($_ -as [int]) -gt 0 -and [int]$_ -ne $SelfPr } | ForEach-Object { [int]$_ })
        if ($others.Count -gt 0) {
            $foreign += [pscustomobject]@{ Sha = $c.Sha; OtherPrs = @($others | Sort-Object -Unique) }
        }
    }
    return @($foreign)
}

# Marker that identifies a review published as a PR COMMENT rather than as a GitHub review object.
# Needed because the reviewers that actually show up on this repo do not all submit review objects:
# the `claude-review` workflow comments, and an external reviewer (second-opinion / Codex) has no
# GitHub identity at all. Without a way to recognise those, the gate can only ever see "0 reviews".
$script:ExternalReviewMarker = '[abios-review]'

<#
    Decide whether this PR was ACTUALLY reviewed, and by whom (#510).

    The distinction the gate was missing: "reviewed, found nothing" and "the reviewer never spoke"
    both arrived as zero findings, and the second one was reported as a pass. A green check from a
    reviewer that produced no review is not evidence of anything, and on this repo it was the only
    reviewer - Copilot has been quota-blocked for weeks.

    Counts two kinds of evidence:
      - a submitted GitHub review (APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED)
      - a PR comment whose body carries the [abios-review] marker

    Returns @{ reviewed; github; external; reviewers }. Pure.
#>
function Get-ReviewEvidence {
    param(
        $Reviews = @(),              # nodes with .state and .author.login
        [string[]]$CommentBodies = @()
    )
    $gh = @(@($Reviews) | Where-Object { $_ -and "$($_.state)".Trim() })
    # Literal containment, NOT -like: the marker's own square brackets are a wildcard character
    # class to -like, which threw "wildcard pattern is not valid" and would have made every
    # external review invisible - the exact blindness this function exists to remove.
    $marker = $script:ExternalReviewMarker
    $ext = @(@($CommentBodies) | Where-Object { "$_".Contains($marker) })

    $names = @()
    foreach ($r in $gh) { if ($r.author.login) { $names += "$($r.author.login)" } }
    foreach ($c in $ext) {
        # `<!-- [abios-review] codex/gpt-5.5 -->` -> "codex/gpt-5.5"; unnamed markers stay generic.
        # Non-greedy up to the comment close: excluding '-' from the name (the first attempt) cut
        # "codex/gpt-5.5" at its own hyphen.
        $name = ''
        if ("$c" -match '(?i)\[abios-review\]\s*(.*?)\s*(?:-->|\r|\n|$)') { $name = $Matches[1].Trim() }
        $names += $(if ($name) { $name } else { 'external' })
    }
    return @{
        reviewed  = (($gh.Count + $ext.Count) -gt 0)
        github    = $gh.Count
        external  = $ext.Count
        reviewers = @($names | Where-Object { $_ } | Select-Object -Unique)
    }
}

# Dot-source guard: tests set $env:ABIOS_REVIEWGATE_DOTSOURCE to load the pure helper only.
if ($env:ABIOS_REVIEWGATE_DOTSOURCE) { return }

# gh must fail closed on the sites that DRIVE the gate verdict and the ruleset write (#303/#316):
# a false-empty review read reads as "0 unresolved -> GATE PASSED" and authorizes a merge. The
# CI/review POLLING reads stay best-effort (a transient failure must keep polling, not throw).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# Per-account memory of Copilot (un)availability so the gate stops re-requesting + waiting (#367).
. (Join-Path $PSScriptRoot 'CopilotAvailability.ps1')

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

$rp = $Repo -split "/"

# ==============================================================================
# -InstallRuleset: require a PR before merging into the default branch
# ==============================================================================
if ($InstallRuleset) {
    $name = "pr-before-merge (agentic-board)"
    # -Json fails closed: a read failure must not read as "no rulesets" and POST a DUPLICATE.
    $existing = Invoke-Gh -GhArgs @('api',"repos/$Repo/rulesets") -What "leer los rulesets de $Repo" -Json
    if (@($existing | Where-Object { $_.name -eq $name }).Count -gt 0) {
        Write-Host "Ruleset '$name' ya existe en $Repo - nada que hacer." -ForegroundColor Green
        exit 0
    }
    $payload = @{
        name        = $name
        target      = "branch"
        enforcement = "active"
        conditions  = @{ ref_name = @{ include = @("~DEFAULT_BRANCH"); exclude = @() } }
        rules       = @(@{
            type       = "pull_request"
            parameters = @{
                required_approving_review_count   = 0
                dismiss_stale_reviews_on_push     = $false
                require_code_owner_review         = $false
                require_last_push_approval        = $false
                required_review_thread_resolution = $true
                allowed_merge_methods             = @("squash", "merge", "rebase")
            }
        })
        bypass_actors = @(@{ actor_id = 5; actor_type = "RepositoryRole"; bypass_mode = "always" })
    } | ConvertTo-Json -Depth 10
    # plain -StdIn: a native non-zero never threw, so the write silently no-op'd and still printed
    # "OK instalado" - the ruleset the user believes protects the branch was never created (#316).
    $null = Invoke-Gh -GhArgs @('api',"repos/$Repo/rulesets",'-X','POST','--input','-') -StdIn $payload `
                      -What "instalar el ruleset '$name' en $Repo"
    Write-Host "OK ruleset '$name' instalado: PRs obligatorios hacia la rama default de $Repo." -ForegroundColor Green
    Write-Host "NOTA honesta: los admins del repo tienen bypass (el tooling sigue funcionando);" -ForegroundColor DarkGray
    Write-Host "la proteccion dura para humanos, el gate del flujo work aplica para el agente." -ForegroundColor DarkGray
    exit 0
}

if ($PR -le 0) { throw "Usa -PR <numero> (o -InstallRuleset)." }

# ── Record an external review so the gate can see it (#510) ───────────────────
# A reviewer without a GitHub identity (second-opinion / Codex, or a careful human read) leaves no
# review object, so to the gate it was indistinguishable from nobody looking. This writes the
# evidence in the one place that survives the session: the PR itself.
if ($RecordReview) {
    $body = @"
<!-- $script:ExternalReviewMarker $Reviewer -->
## Revision externa - $Reviewer

$(if ($Summary) { $Summary } else { "Revision realizada sobre el diff de este PR." })
"@
    $null = Invoke-Gh -GhArgs @('pr','comment',"$PR",'--repo',$Repo,'--body',$body) `
                      -What "registrar la revision externa en el PR #$PR"
    Write-Host "OK revision de '$Reviewer' registrada en el PR #$PR - el gate ya la cuenta como review." -ForegroundColor Green
    exit 0
}

Write-Host "=== Review gate  $Repo  PR #$PR ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. Request a Copilot code review (best-effort) ────────────────────────────
# Confirming the request used to false-negative: an immediate re-query can miss the
# freshly added reviewer (eventual consistency), printing "no disponible" even when
# Copilot WAS added. Instead we trust the POST response body (its requested_reviewers
# is authoritative and immediate) and fall back to a short GET retry.
$copilotRequested = $false
$copilotSkipped   = $false
$copilotOwner     = ($Repo -split '/')[0]

function Test-CopilotPending {
    # GET the current requested reviewers; the Copilot bot shows up under .users as
    # login "Copilot". Returns $true when it is present.
    $rr = gh api "repos/$Repo/pulls/$PR/requested_reviewers" 2>$null | ConvertFrom-Json
    return [bool](@($rr.users) | Where-Object { $_.login -match '(?i)copilot' })
}

# -EnableCopilot: forget the "unavailable" marker for this owner and try Copilot again this run (#367).
if ($EnableCopilot -and (Clear-CopilotUnavailable $copilotOwner)) {
    Write-Host "  Copilot re-habilitado para $copilotOwner (marcador borrado)." -ForegroundColor DarkGray
}

# If we already know this ACCOUNT has no Copilot, skip the request AND the wait entirely and route to
# self-review — do not re-ask a reviewer that answered "no quota" days ago (#367). Self-healing: an
# expired cooldown falls through to a real request below.
$copilotSkip = Test-CopilotShouldSkip -Owner $copilotOwner -Now (Get-Date)
if ($copilotSkip.Skip) {
    $copilotSkipped = $true
    $untilTxt = if ($copilotSkip.Until) { " hasta $($copilotSkip.Until)" } else { "" }
    Write-Host "  Copilot marcado como NO disponible para $copilotOwner$untilTxt - salto la solicitud y la espera (#367)." -ForegroundColor DarkYellow
    Write-Host "       Fallback obligatorio: self-review explicito de 'gh pr diff $PR' antes de mergear" -ForegroundColor DarkYellow
    Write-Host "       (usa -EnableCopilot para reintentar ahora, o la skill second-opinion como revisor)." -ForegroundColor DarkYellow
}

if (-not $copilotSkipped) {
    try {
        $postResp = gh api "repos/$Repo/pulls/$PR/requested_reviewers" -X POST `
            -f "reviewers[]=copilot-pull-request-reviewer[bot]" 2>$null | ConvertFrom-Json
        # A failed POST (Copilot not enabled) yields an error object with no requested_reviewers.
        if ($postResp -and (@($postResp.requested_reviewers) | Where-Object { $_.login -match '(?i)copilot' })) {
            $copilotRequested = $true
        }
    } catch { }

    if (-not $copilotRequested) {
        # Eventual consistency: the reviewer may take a moment to surface (also covers a
        # re-run where the bot was already requested and the POST returned no fresh body).
        # Don't sleep after the final attempt - there is no re-check after it.
        foreach ($attempt in 1..3) {
            if (Test-CopilotPending) { $copilotRequested = $true; break }
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }

    if ($copilotRequested) {
        Write-Host "  OK  Review de Copilot solicitado (reviewer pendiente confirmado)" -ForegroundColor Green
    } else {
        Write-Host "  WARN Copilot code review no disponible en esta cuenta/repo." -ForegroundColor DarkYellow
        Write-Host "       Fallback obligatorio: self-review explicito de 'gh pr diff $PR' antes de mergear," -ForegroundColor DarkYellow
        Write-Host "       y si la skill second-opinion esta disponible, usala como segundo revisor." -ForegroundColor DarkYellow
    }
}

# ── 1.5. Small-PR guard (GitHub PR BP: small, focused pull requests) ──────────
# -Json fails closed: a read failure must not yield null additions (-> 0 lines) that silently
# skips the small-PR guard for a PR that could be huge (#316).
$size = Invoke-Gh -GhArgs @('pr','view',"$PR",'--repo',$Repo,'--json','additions,deletions,changedFiles') `
                  -What "leer el tamano del PR #$PR" -Json
$totalLines = $size.additions + $size.deletions
Write-Host ""
Write-Host ("  Tamano del PR: {0} archivo(s), +{1}/-{2} ({3} lineas)" -f $size.changedFiles, $size.additions, $size.deletions, $totalLines) -ForegroundColor Cyan
if ($totalLines -gt $MaxLines -or $size.changedFiles -gt $MaxFiles) {
    Write-Host "  WARN PR grande (umbral: $MaxLines lineas / $MaxFiles archivos)." -ForegroundColor DarkYellow
    Write-Host "       Un PR chico se revisa mejor y mete menos bugs. Considera dividir el issue con:" -ForegroundColor DarkYellow
    Write-Host "       Board-Breakdown.ps1 -Parent <issueNum> -Tasks `"parte A`", `"parte B`"" -ForegroundColor DarkYellow
    Write-Host "       (advertencia, no bloqueo - los umbrales se ajustan con -MaxLines/-MaxFiles)" -ForegroundColor DarkGray
}

# ── 1.6. Foreign-commit guard (#309): warn when the PR carries commits from another PR ─────────
# Defence-in-depth for #294 — an issue branch should start from the freshly fetched default branch,
# but when no base can be resolved Board-Work falls back to the current HEAD, and a hand-cut branch
# bypasses that entirely. This is the backstop for exactly that case: a commit GitHub associates with
# a DIFFERENT PR is not this issue's work. Warn-only, like the small-PR guard — it never feeds
# $blockers below.
$prCommits = Invoke-Gh -GhArgs @('pr','view',"$PR",'--repo',$Repo,'--json','commits') `
                       -What "leer los commits del PR #$PR" -Json
$commitInfo = @()
foreach ($c in @($prCommits.commits)) {
    $sha = $c.oid
    if (-not $sha) { continue }
    # commits/{sha}/pulls: which PRs contain this commit. Best-effort PER COMMIT — a lookup failure
    # is a skipped signal, never a failed gate (this is only a warning), so it is caught and dropped.
    $pulls = @()
    try {
        $assoc = Invoke-Gh -GhArgs @('api',"repos/$Repo/commits/$sha/pulls",'--jq','[.[].number]') `
                           -What "leer los PRs del commit $sha"
        if ($assoc) { $pulls = @(($assoc | ConvertFrom-Json)) }
    } catch { }
    $commitInfo += [pscustomobject]@{ Sha = $sha; Pulls = $pulls }
}
$foreign = Find-ForeignCommits -SelfPr $PR -Commits $commitInfo
if (@($foreign).Count -gt 0) {
    Write-Host ""
    Write-Host ("  WARN el PR trae {0} commit(s) asociado(s) a OTRO PR - probablemente no son el trabajo de este issue (#309):" -f @($foreign).Count) -ForegroundColor DarkYellow
    foreach ($f in $foreign) {
        $short = $f.Sha.Substring(0, [Math]::Min(9, $f.Sha.Length))
        Write-Host ("       {0}  -> PR(s) {1}" -f $short, ($f.OtherPrs -join ', ')) -ForegroundColor DarkYellow
    }
    Write-Host "       Verifica que la rama haya salido de la default branch fresca (Board-Work sale de origin/main)." -ForegroundColor DarkGray
    Write-Host "       (advertencia, no bloqueo - un commit contaminante sin PR propio es invisible a esta senal)" -ForegroundColor DarkGray
}

# ── 1.7 + 1.8. Semantic-model quality gates (M3.3): breaking schema changes AND BPA ──
# These are the model-quality blocks the gate was built toward. Both act ONLY when the PR touches a
# TMDL model, so a non-BI repo is unaffected; both feed $blockers below (a merge is stopped the same
# way a failing CI check stops it). Each degrades safely - a missing runner/tool is a WARN + skip,
# never a block, so a merge is only ever stopped by an actual finding.
# plain: --jq emits filtered text (not JSON). A genuinely no-.tmdl PR returns empty at exit 0 (fine),
# but a READ FAILURE must throw instead of silently skipping the model reviews (#316).
$tmdlBlocked = $false
$bpaBlocked  = $false
$tmdlChanged = Invoke-Gh -GhArgs @('api',"repos/$Repo/pulls/$PR/files",'--paginate','--jq','.[] | select(.filename | endswith(".tmdl")) | .filename') `
                         -What "leer los archivos del PR #$PR"
if ($tmdlChanged) {
    Write-Host ""
    Write-Host "  Cambios en modelo TMDL detectados - corriendo reviews de esquema + BPA..." -ForegroundColor Cyan
    # 1.7 TMDL breaking-change diff - now BLOCKING (M3.3): -FailOnBreaking exits 1 on a BREAKING change.
    $tmdlScript = Join-Path $PSScriptRoot "Tmdl-DiffReview.ps1"
    if (Test-Path $tmdlScript) {
        & $tmdlScript -Repo $Repo -PR $PR -FailOnBreaking
        if ($LASTEXITCODE -ne 0) { $tmdlBlocked = $true }
    } else {
        Write-Host "  WARN Tmdl-DiffReview.ps1 no encontrado junto al gate - salteando review TMDL." -ForegroundColor DarkYellow
    }
    # 1.8 Best Practice Analyzer - BLOCKING on error-severity violations (#16). Skips safely when the
    # repo has no BPA rules or Tabular Editor is absent (those are never a block).
    $bpaScript = Join-Path $PSScriptRoot "Bpa-GateReview.ps1"
    if (Test-Path $bpaScript) {
        & $bpaScript -Repo $Repo -PR $PR -FailOn error
        if ($LASTEXITCODE -ne 0) { $bpaBlocked = $true }
    } else {
        Write-Host "  WARN Bpa-GateReview.ps1 no encontrado junto al gate - salteando BPA." -ForegroundColor DarkYellow
    }
}

# ── 2. CI checks ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Esperando checks de CI..." -ForegroundColor Cyan
$checksOk = $true
$checksOut = gh pr checks $PR --repo $Repo --watch 2>&1
$checksExit = $LASTEXITCODE
$checksText = ($checksOut | Out-String).Trim()
if ($checksText) { Write-Host $checksText }
if ($checksExit -ne 0) {
    if ($checksText -match '(?i)no checks') {
        Write-Host "  (sin checks configurados - cuenta como pass, considera /board automate)" -ForegroundColor DarkGray
    } else {
        $checksOk = $false
        Write-Host "  FAIL hay checks fallando" -ForegroundColor Red
    }
} else {
    Write-Host "  OK  checks en verde" -ForegroundColor Green
}

# ── 3. Wait for the review, then collect decision + threads ───────────────────
function Get-ReviewState {
    # THE gate verdict read. -Graphql throws on exit OR errors[] so a failed read can never come
    # back as 0 reviews / 0 unresolved / null decision -> a false GATE PASSED that authorizes a
    # merge. -Retries rides out a transient blip during the poll; a hard failure fails the gate (#316).
    $reviewQuery = '
query($o:String!, $r:String!, $n:Int!) {
  repository(owner:$o, name:$r) {
    pullRequest(number:$n) {
      reviewDecision
      reviews(last:20) { nodes { author { login } state body submittedAt } }
      reviewThreads(first:50) { nodes { isResolved } }
    }
  }
}'
    $q = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$reviewQuery",'-f',"o=$($rp[0])",'-f',"r=$($rp[1])",'-F',"n=$PR") `
                   -What "leer el estado del review del PR #$PR" -Graphql -Retries 2
    return $q.data.repository.pullRequest
}

# NOTE: variable must NOT be named $pr - PowerShell vars are case-insensitive and it would
# collide with the [int]$PR parameter (type conversion crash).
$prState = Get-ReviewState
if ($copilotRequested) {
    Write-Host ""
    Write-Host "  Esperando el review (max $TimeoutMinutes min)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $reviews = @($prState.reviews.nodes)
        if ($reviews.Count -gt 0 -and ($reviews | Where-Object { $_.author.login -match '(?i)copilot' })) { break }
        Start-Sleep -Seconds 20
        $prState = Get-ReviewState
    }
}

$reviews    = @($prState.reviews.nodes)
$unresolved = @($prState.reviewThreads.nodes | Where-Object { $_.isResolved -eq $false }).Count
$decision   = $prState.reviewDecision

# If Copilot answered that it could NOT review (no quota), remember it per account so the NEXT PR skips
# the request + the wait entirely (#367). Only when we actually requested it this run — a skipped run
# has nothing new to learn. Best-effort: a marker write failure never affects the gate verdict.
if ($copilotRequested -and (Test-CopilotUnavailableReview $reviews)) {
    $cooldownDays = [Math]::Max(1, $CopilotCooldownDays)
    if (Set-CopilotUnavailable -Owner $copilotOwner -Until (Get-Date).AddDays($cooldownDays) -Reason 'Copilot answered: unable to review (quota/limit)') {
        Write-Host ("  Copilot sin disponibilidad detectada - marcado NO disponible para {0} por {1} dia(s); no lo volvere a solicitar/esperar hasta entonces (#367)." -f $copilotOwner, $cooldownDays) -ForegroundColor DarkYellow
    }
}

# Evidence that someone ACTUALLY reviewed (#510). Comments are read separately from reviews because
# the reviewers that show up on this repo comment instead of submitting review objects.
$commentBodies = @()
try {
    $cj = Invoke-Gh -GhArgs @('pr','view',"$PR",'--repo',$Repo,'--json','comments') -What "leer los comentarios del PR #$PR"
    $commentBodies = @(($cj | ConvertFrom-Json).comments | ForEach-Object { "$($_.body)" })
} catch {
    # Fail CLOSED: an unreadable comment list must not be able to manufacture "reviewed".
    Write-Host "  WARN no pude leer los comentarios del PR - la evidencia de revision se cuenta solo por reviews." -ForegroundColor DarkYellow
}
$evidence = Get-ReviewEvidence -Reviews $reviews -CommentBodies $commentBodies

Write-Host ""
Write-Host "----- RESULTADO DEL REVIEW -----" -ForegroundColor Cyan
Write-Host ("Decision      : {0}" -f ($(if ($decision) { $decision } else { "(sin reviews requeridos)" })))
Write-Host ("Reviews       : {0}" -f $reviews.Count)
foreach ($r in $reviews) {
    Write-Host ("  [{0}] {1} - {2}" -f $r.state, $r.author.login, $r.submittedAt) -ForegroundColor Yellow
    if ($r.body) { Write-Host ("    {0}" -f $r.body) }
}
Write-Host ("Hilos abiertos: {0}" -f $unresolved)
if ($unresolved -gt 0) {
    Write-Host "  Comentarios sin resolver (path:linea):" -ForegroundColor Yellow
    gh api "repos/$Repo/pulls/$PR/comments" --jq '.[] | "  \(.path):\(.line // .original_line)  [\(.user.login)] \(.body)"' 2>$null |
        Select-Object -First 30 | ForEach-Object { Write-Host $_ }
}
Write-Host "--------------------------------" -ForegroundColor Cyan
Write-Host ""

# ── 4. Verdict ─────────────────────────────────────────────────────────────────
$blockers = @()
if (-not $checksOk)                        { $blockers += "checks de CI fallando" }
if ($decision -eq "CHANGES_REQUESTED")     { $blockers += "review pide cambios (CHANGES_REQUESTED)" }
if ($unresolved -gt 0)                     { $blockers += "$unresolved hilo(s) de review sin resolver" }
if ($tmdlBlocked)                          { $blockers += "cambios TMDL BREAKING en el modelo (M3.3)" }
if ($bpaBlocked)                           { $blockers += "violaciones BPA de severidad error (M3.3)" }

if ($blockers.Count -eq 0) {
    # THE #510 fix. "Reviewed and found nothing" and "nobody ever looked" used to print the same
    # GATE PASSED with a reminder underneath - and a caller that reads the exit code saw a pass
    # either way. Silence is not approval, so the second case gets its own verdict and its own
    # exit code: anything testing `-eq 0` now fails closed, while still telling it apart from a
    # real block (exit 1).
    if (-not $evidence.reviewed -and -not $AllowUnreviewed) {
        Write-Host "GATE SIN REVISAR - los checks estan en verde, pero NADIE reviso este PR." -ForegroundColor Yellow
        Write-Host "  0 reviews de GitHub y 0 revisiones externas registradas." -ForegroundColor Yellow
        Write-Host "  Un check verde de un reviewer que no dejo review no es evidencia de nada (#510)." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Salidas legitimas, en orden de preferencia:" -ForegroundColor Cyan
        Write-Host "   1. Que alguien revise de verdad - el revisor externo (second-opinion) sirve," -ForegroundColor Cyan
        Write-Host "      y se registra con -RecordReview -Reviewer <quien> -Summary <que encontro>." -ForegroundColor DarkGray
        Write-Host "   2. Si de verdad no amerita revision (typo, archivo generado): -AllowUnreviewed." -ForegroundColor DarkGray
        Write-Host ""
        exit 2
    }
    Write-Host "GATE PASSED - seguro mergear." -ForegroundColor Green
    if ($evidence.reviewed) {
        Write-Host ("  Revisado por: {0} ({1} review(s) de GitHub, {2} externa(s))." -f `
            ($evidence.reviewers -join ', '), $evidence.github, $evidence.external) -ForegroundColor Green
    } else {
        Write-Host "  NOTA: pasa SIN revision porque se pidio -AllowUnreviewed. Nadie miro este codigo." -ForegroundColor DarkYellow
    }
    exit 0
} else {
    Write-Host "GATE BLOCKED:" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "Atiende el feedback, push, y re-ejecuta este gate." -ForegroundColor Yellow
    exit 1
}

