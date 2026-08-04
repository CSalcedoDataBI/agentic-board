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
         SILENCE arms it too (#563): a requested Copilot that never answers
         within the review timeout gets a 1-day marker, so the next PR skips
         the wait instead of paying it forever. And the wait itself breaks on
         ANY review bound to the current head, not only Copilot's.
      2. If the PR touches any *.tmdl (a PBIP semantic model), runs the two
         model-quality gates and BLOCKS on either (M3.3):
           - TMDL diff review (Tmdl-DiffReview.ps1 -FailOnBreaking): a BREAKING
             schema change blocks the merge.
           - Best Practice Analyzer (Bpa-GateReview.ps1 -FailOn error): an
             error-severity BPA violation blocks the merge.
         Both degrade safely: no model, no BPA rules file, or no Tabular Editor
         is a WARN + skip, never a block - a merge is only ever stopped by an
         actual finding. A non-BI repo never triggers either.
      3. Waits for CI checks AND the requested review in ONE bounded loop
         (#562). Both waits are independent, so they run concurrently: total
         wait is max(CI, review), not their sum. The CI side is capped at
         -CiTimeoutMinutes — the previous `gh pr checks --watch` had no
         timeout, so a queued/stuck workflow hung the session indefinitely;
         now it expires into an explicit "CI still pending" BLOCK. "No checks
         configured" counts as pass, with a note.
      4. Reports: review decision, every review with author/state/body, and
         unresolved review-thread count.
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

.PARAMETER CiTimeoutMinutes
    Max minutes to wait for CI checks to settle. Default 25 (the repo's CI
    jobs cap at 20). Expiry is an explicit block ("CI still pending"), never
    a silent hang — this bound exists because the unbounded watch was the
    only wait in the codebase with no ceiling (#562).

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
    # Ceiling for the CI wait (#562). The old `--watch` could hang forever on a queued workflow.
    [int]   $CiTimeoutMinutes = 25,
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
    Decide whether THIS DIFF was actually reviewed, and by whom (#510).

    The distinction the gate was missing: "reviewed, found nothing" and "the reviewer never spoke"
    both arrived as zero findings, and the second one was reported as a pass. A green check from a
    reviewer that produced no review is not evidence of anything, and on this repo it was the only
    reviewer - Copilot has been quota-blocked for weeks.

    EVERY piece of evidence is bound to the PR's head SHA, and that is not a detail. Counting any
    review ever left on the PR reproduces the original defect one level up: push three more commits
    after an approval and the gate would authorise a diff nobody had read, on the strength of a
    review of different code. So a review counts only for the commit it was performed on.

    The cost is deliberate and small: a new push invalidates the evidence and the reviewer has to
    look again (or re-record). That is the correct reading - the new commits genuinely have not
    been reviewed.

    Counts two kinds of evidence, both SHA-bound:
      - a submitted GitHub review whose commit is the current head
      - a PR comment carrying `[abios-review] <who> sha=<head>`

    Returns @{ reviewed; github; external; reviewers; stale }. `stale` counts evidence that exists
    but belongs to an older commit, so the caller can say WHY it does not count. Pure.
#>
function Get-ReviewEvidence {
    param(
        $Reviews = @(),              # nodes with .state, .author.login, .commit.oid
        [string[]]$CommentBodies = @(),
        [string]$HeadSha = ''
    )
    $head = "$HeadSha".Trim()

    # Literal containment, NOT -like: the marker's own square brackets are a wildcard character
    # class to -like, which threw "wildcard pattern is not valid" and would have made every
    # external review invisible - the exact blindness this function exists to remove.
    $marker    = $script:ExternalReviewMarker
    $allExt    = @(@($CommentBodies) | Where-Object { "$_".Contains($marker) })
    $allGh     = @(@($Reviews) | Where-Object { $_ -and "$($_.state)".Trim() })

    # With no head SHA to compare against we cannot prove ANY evidence belongs to this diff. Fail
    # closed: report nothing reviewed rather than accept evidence we cannot place.
    if (-not $head) {
        return @{ reviewed = $false; github = 0; external = 0; reviewers = @()
                  stale = ($allGh.Count + $allExt.Count) }
    }

    $gh  = @($allGh  | Where-Object { "$($_.commit.oid)".Trim() -eq $head })
    $ext = @($allExt | Where-Object { "$_" -match ('(?i)sha\s*=\s*' + [regex]::Escape($head)) })

    $names = @()
    foreach ($r in $gh) { if ($r.author.login) { $names += "$($r.author.login)" } }
    foreach ($c in $ext) {
        # `<!-- [abios-review] codex/gpt-5.5 sha=abc… -->` -> "codex/gpt-5.5". Non-greedy up to the
        # sha; excluding '-' from the name (the first attempt) cut "codex/gpt-5.5" at its hyphen.
        $name = ''
        if ("$c" -match '(?i)\[abios-review\]\s*(.*?)\s*(?:sha\s*=|-->|\r|\n|$)') { $name = $Matches[1].Trim() }
        $names += $(if ($name) { $name } else { 'external' })
    }
    return @{
        reviewed  = (($gh.Count + $ext.Count) -gt 0)
        github    = $gh.Count
        external  = $ext.Count
        reviewers = @($names | Where-Object { $_ } | Select-Object -Unique)
        stale     = (($allGh.Count - $gh.Count) + ($allExt.Count - $ext.Count))
    }
}

# Names that identify the automated REVIEWER job rather than a build/test job. Matched loosely
# because `gh pr checks` reports the check-run display name, which repos namespace differently
# (`PR Review (@claude) / claude-review`, `claude-review`, `Copilot review`...). Being generous
# here is safe: the only thing this unlocks is ignoring a reviewer's red AFTER a real review is
# already on record, and every non-reviewer failure still blocks.
$script:ReviewerCheckPattern = '(?i)(claude|copilot)[-_ /]*review|review[-_ /]*(claude|copilot)|^\s*pr[-_ ]?review\s*$'

function Test-IsReviewerCheck {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if (-not "$Name".Trim()) { return $false }
    return [bool]("$Name" -match $script:ReviewerCheckPattern)
}

<#
    Is the ONLY thing red the automated reviewer?

    Gates a narrow allowance: a reviewer job failing asks "was this reviewed?", not "does the code
    work?" - and once a real review is on record for the commit, that question is answered. Without
    it, every PR that edits `pr-review.yml` deadlocks, because `claude-code-action` skips itself on
    exactly those PRs.

    $Parsed says whether the check list was read from STRUCTURED data. It is not a formality: the
    first cut scraped the human-readable `gh pr checks` output, so any failure printed in a shape
    the regex missed would silently vanish from the list, a reviewer failure would then be the only
    one seen, and a genuinely broken build would be waved through. Unparsed => never downgrade.
#>
function Test-OnlyReviewerChecksFailed {
    param(
        [string[]]$FailedChecks = @(),
        [bool]$Parsed = $false,
        # The snapshot must be SETTLED for the allowance to mean anything (#562, external review):
        # with checks still pending at the CI deadline, "the only FAILURE is the reviewer" says
        # nothing about the pending ones - excusing the reviewer there would excuse the timeout.
        [bool]$Settled = $true
    )
    if (-not $Parsed)  { return $false }                      # cannot enumerate -> never downgrade
    if (-not $Settled) { return $false }                      # pending checks -> nothing is excused
    $names = @(@($FailedChecks) | Where-Object { "$_".Trim() })
    if ($names.Count -eq 0) { return $false }                 # nothing named -> nothing to excuse
    foreach ($n in $names) { if (-not (Test-IsReviewerCheck $n)) { return $false } }
    return $true
}

<#
    Classify one structured snapshot of `gh pr checks --json name,bucket` (#562).

    Buckets per gh: pass / fail / pending / skipping / cancel. 'cancel' counts as failed (a
    cancelled check did not pass) and 'skipping' as settled-ok — both mirror the previous
    verdict logic, just computed from one snapshot instead of trusting --watch's exit code.

    Fails closed: an unparsed snapshot ($Parsed=$false) reports Settled=$false and Ok=$false,
    so the caller keeps polling and, at the deadline, blocks with a readable reason instead of
    inventing a pass from data it never saw. An empty parsed list is the "no checks configured"
    case — settled and ok, with NoChecks so the caller can print the note. Pure.
#>
function Get-ChecksVerdict {
    param(
        $Checks = @(),
        [bool]$Parsed = $false
    )
    if (-not $Parsed) {
        return @{ Parsed = $false; Settled = $false; Ok = $false; NoChecks = $false; Failed = @(); Pending = @() }
    }
    $list = @(@($Checks) | Where-Object { $_ })
    if ($list.Count -eq 0) {
        return @{ Parsed = $true; Settled = $true; Ok = $true; NoChecks = $true; Failed = @(); Pending = @() }
    }
    $failed  = @($list | Where-Object { "$($_.bucket)" -in @('fail','cancel') } | ForEach-Object { "$($_.name)" })
    $pending = @($list | Where-Object { "$($_.bucket)" -eq 'pending' }          | ForEach-Object { "$($_.name)" })
    return @{
        Parsed   = $true
        Settled  = ($pending.Count -eq 0)
        Ok       = ($pending.Count -eq 0 -and $failed.Count -eq 0)
        NoChecks = $false
        Failed   = $failed
        Pending  = $pending
    }
}

<#
    Should the combined CI+review wait loop exit? (#562)

    The two waits are independent, so the loop runs them CONCURRENTLY and exits only when both
    sides are done: the CI side when checks settle or its deadline passes, the review side when
    no review is being waited on, or one arrived, or its deadline passes. This is what turns
    the old sequential worst case (CI wait + full review wait) into max(CI, review). Pure.
#>
function Test-GateWaitDone {
    param(
        [bool]$ChecksSettled,
        [bool]$WaitingReview,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][datetime]$CiDeadline,
        [Parameter(Mandatory)][datetime]$ReviewDeadline
    )
    $ciDone     = $ChecksSettled -or ($Now -ge $CiDeadline)
    $reviewDone = (-not $WaitingReview) -or ($Now -ge $ReviewDeadline)
    return ($ciDone -and $reviewDone)
}

<#
    Did a review land FOR THE CURRENT HEAD? (#563)

    The wait loop used to break only on a review whose AUTHOR matched 'copilot' — a human or an
    external reviewer landing mid-poll kept the loop spinning for the full timeout even though the
    thing being waited for (an answer about this diff) had already arrived. Any review bound to the
    current head ends the wait now. Stale reviews from earlier commits do NOT end it: they are
    exactly the evidence Get-ReviewEvidence refuses, so breaking on them would end the wait with
    nothing to show for it. Pure.
#>
function Test-FreshReviewArrived {
    param(
        $Reviews = @(),
        [string]$HeadSha = ''
    )
    $head = "$HeadSha".Trim()
    if (-not $head) { return $false }
    return [bool](@($Reviews) | Where-Object { $_ -and "$($_.commit.oid)".Trim() -eq $head })
}

<#
    Did Copilot stay SILENT past the review deadline? (#563)

    The per-account cooldown (#367) only armed when Copilot ANSWERED "cannot review" — an explicit
    refusal review object. A Copilot that never says anything taught the gate nothing, so every PR
    burned the full review timeout forever, which is the worst of both: the wait was always paid
    and the self-healing never triggered. Silence past the deadline is now evidence too. Pure.
#>
function Test-CopilotSilentTimeout {
    param(
        [bool]$Requested,
        [bool]$Answered,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][datetime]$Deadline
    )
    return ($Requested -and (-not $Answered) -and ($Now -ge $Deadline))
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
    # A summary is REQUIRED. Without it this is a one-flag way to stamp "reviewed" on a PR nobody
    # read - the same empty assurance the whole issue is about, just with a different author.
    # Having to state what the review found is the cheapest available proof that one happened.
    if (-not "$Summary".Trim()) {
        throw "-RecordReview exige -Summary: escribe QUE encontro la revision. Registrar una revision vacia es exactamente el problema que este gate arregla (#510)."
    }
    $headJson = Invoke-Gh -GhArgs @('pr','view',"$PR",'--repo',$Repo,'--json','headRefOid') `
                          -What "leer el head del PR #$PR"
    $headSha  = "$(($headJson | ConvertFrom-Json).headRefOid)".Trim()
    if (-not $headSha) { throw "No pude leer el head del PR #$PR - sin el, la revision no queda atada a este diff." }

    # The SHA is what makes the record mean something: it attests to THIS diff, not to the PR in
    # general. A later push leaves it behind as stale evidence instead of vouching for code the
    # reviewer never saw.
    $body = @"
<!-- $script:ExternalReviewMarker $Reviewer sha=$headSha -->
## Revision externa - $Reviewer

**Commit revisado:** ``$headSha``

$Summary
"@
    $null = Invoke-Gh -GhArgs @('pr','comment',"$PR",'--repo',$Repo,'--body',$body) `
                      -What "registrar la revision externa en el PR #$PR"
    Write-Host "OK revision de '$Reviewer' registrada sobre el commit $($headSha.Substring(0,[Math]::Min(7,$headSha.Length))) del PR #$PR." -ForegroundColor Green
    Write-Host "   Si empujas commits nuevos, esta revision deja de contar - y debe ser asi." -ForegroundColor DarkGray
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

# ── 2+3. CI checks AND review, waited together (bounded + concurrent, #562) ───
# The old shape was two waits in sequence: `gh pr checks --watch` (no timeout — the only unbounded
# wait in the codebase; a queued workflow hung the session forever) and THEN a review poll. They
# are independent, so one loop now polls both: worst case is max(CI, review), not their sum, and
# the CI side expires at -CiTimeoutMinutes into an explicit "still pending" block.
function Get-ReviewState {
    # THE gate verdict read. -Graphql throws on exit OR errors[] so a failed read can never come
    # back as 0 reviews / 0 unresolved / null decision -> a false GATE PASSED that authorizes a
    # merge. -Retries rides out a transient blip during the poll; a hard failure fails the gate (#316).
    $reviewQuery = '
query($o:String!, $r:String!, $n:Int!) {
  repository(owner:$o, name:$r) {
    pullRequest(number:$n) {
      headRefOid
      reviewDecision
      reviews(last:20) { nodes { author { login } state body submittedAt commit { oid } } }
      reviewThreads(first:50) { nodes { isResolved } }
    }
  }
}'
    $q = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$reviewQuery",'-f',"o=$($rp[0])",'-f',"r=$($rp[1])",'-F',"n=$PR") `
                   -What "leer el estado del review del PR #$PR" -Graphql -Retries 2
    return $q.data.repository.pullRequest
}

Write-Host ""
if ($copilotRequested) {
    Write-Host "  Esperando checks de CI (max $CiTimeoutMinutes min) y el review (max $TimeoutMinutes min) EN PARALELO..." -ForegroundColor Cyan
} else {
    Write-Host "  Esperando checks de CI (max $CiTimeoutMinutes min)..." -ForegroundColor Cyan
}

$ciDeadline     = (Get-Date).AddMinutes([Math]::Max(1, $CiTimeoutMinutes))
$reviewDeadline = (Get-Date).AddMinutes([Math]::Max(1, $TimeoutMinutes))
$verdictCi      = Get-ChecksVerdict -Checks @() -Parsed $false
$reviewArrived  = $false
# NOTE: variable must NOT be named $pr - PowerShell vars are case-insensitive and it would
# collide with the [int]$PR parameter (type conversion crash).
$prState        = $null

while ($true) {
    # CI snapshot — STRUCTURED read only (the display-text table was a merge decision made from
    # human-readable output; see the #510 history above). A failed read keeps polling and, at the
    # deadline, blocks — it can never invent a pass.
    $checksJson = gh pr checks $PR --repo $Repo --json name,bucket 2>$null
    $parsedList = @(); $parsedOk = $false
    if ($checksJson) {
        try { $parsedList = @($checksJson | ConvertFrom-Json); $parsedOk = $true } catch { }
    } else {
        # Empty stdout is either "no checks configured" (benign) or a transient read failure.
        # Probe the human-readable form to tell them apart: only the explicit "no checks" text
        # counts as benign; anything else stays unparsed and fails closed at the deadline.
        $probe = (gh pr checks $PR --repo $Repo 2>&1 | Out-String)
        if ($probe -match '(?i)no checks') { $parsedList = @(); $parsedOk = $true }
    }
    $verdictCi = Get-ChecksVerdict -Checks $parsedList -Parsed $parsedOk

    # Review snapshot — while one is awaited, and at least once so the verdict section always has
    # PR state (decision, threads, head SHA) even when no review was requested. ANY review bound
    # to the current head ends the wait, not just Copilot's (#563) — a human or external reviewer
    # answering first is an answer.
    if (-not $prState -or ($copilotRequested -and -not $reviewArrived)) {
        $prState = Get-ReviewState
        $reviewArrived = Test-FreshReviewArrived -Reviews @($prState.reviews.nodes) -HeadSha "$($prState.headRefOid)"
    }

    if (Test-GateWaitDone -ChecksSettled ([bool]$verdictCi.Settled) `
                          -WaitingReview ($copilotRequested -and -not $reviewArrived) `
                          -Now (Get-Date) -CiDeadline $ciDeadline -ReviewDeadline $reviewDeadline) { break }
    Start-Sleep -Seconds 15
}

# Re-read PR state AFTER the wait so the verdict below judges the PRESENT, not a snapshot from
# early in the CI wait (#562, external review): a review that requested changes or a thread opened
# while CI was still running would otherwise be invisible to a verdict computed from stale state.
$prState = Get-ReviewState

# CI verdict, from the last snapshot. The deadline bounds the WAIT, not the validity of a late
# result: if checks settle green while the loop is still open for the review side, that pass is
# real and counts. The invariant that matters is fail-closed and it holds on every path - a pass
# requires a PARSED, SETTLED, all-green snapshot; pending-at-exit and unreadable both block.
$checksOk     = $true
$ciTimedOut   = $false
$failedChecks = @($verdictCi.Failed)
$checksParsed = [bool]$verdictCi.Parsed
if ($verdictCi.NoChecks) {
    Write-Host "  (sin checks configurados - cuenta como pass, considera /board automate)" -ForegroundColor DarkGray
} elseif (-not $verdictCi.Parsed) {
    $checksOk = $false
    Write-Host "  FAIL no pude leer los checks del PR dentro del limite - se bloquea por precaucion, no como pass." -ForegroundColor Red
} elseif (-not $verdictCi.Settled) {
    $checksOk = $false; $ciTimedOut = $true
    Write-Host ("  FAIL checks aun PENDIENTES tras {0} min: {1}" -f $CiTimeoutMinutes, (@($verdictCi.Pending) -join ', ')) -ForegroundColor Red
    Write-Host "       (limite del gate #562 - antes esto esperaba sin techo y colgaba la sesion)" -ForegroundColor DarkGray
} elseif (-not $verdictCi.Ok) {
    $checksOk = $false
    Write-Host ("  FAIL hay checks fallando: {0}" -f ($failedChecks -join ', ')) -ForegroundColor Red
} else {
    Write-Host "  OK  checks en verde" -ForegroundColor Green
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
} elseif ($copilotRequested) {
    # SILENCE past the deadline arms the cooldown too (#563). Without this, a Copilot that never
    # answers anything left the marker unarmed and every PR paid the full wait forever. Silence is
    # weaker evidence than an explicit refusal, so it gets a 1-day cooldown instead of the full
    # -CopilotCooldownDays — a slow day should not silence the reviewer for a week.
    $copilotAnswered = [bool](@($reviews) | Where-Object { $_.author.login -match '(?i)copilot' })
    if (Test-CopilotSilentTimeout -Requested $copilotRequested -Answered $copilotAnswered -Now (Get-Date) -Deadline $reviewDeadline) {
        if (Set-CopilotUnavailable -Owner $copilotOwner -Until (Get-Date).AddDays(1) -Reason "Copilot stayed silent past the $TimeoutMinutes-minute review timeout") {
            Write-Host ("  Copilot no contesto en {0} min - marcado NO disponible para {1} por 1 dia; el proximo PR no pagara esta espera (#563)." -f $TimeoutMinutes, $copilotOwner) -ForegroundColor DarkYellow
        }
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
$evidence = Get-ReviewEvidence -Reviews $reviews -CommentBodies $commentBodies -HeadSha "$($prState.headRefOid)"

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
# A failing REVIEWER check asks "was this reviewed?", not "does the code work?". Once a real
# review is on record for this commit, that question is answered and the reviewer job's own red
# is no longer a reason to block - otherwise the flow deadlocks in a case that is routine:
# `claude-code-action` SKIPS ITSELF (and exits success) on any PR that edits its own workflow
# file, so its verification correctly reports "nobody reviewed" and would then block that PR
# forever, no matter how carefully a human or an external reviewer read it.
# Narrow on purpose: only when EVERY failing check is a reviewer job AND real evidence exists.
if (-not $checksOk -and $evidence.reviewed -and (Test-OnlyReviewerChecksFailed -FailedChecks $failedChecks -Parsed $checksParsed -Settled ([bool]$verdictCi.Settled))) {
    $checksOk = $true
    Write-Host ("  NOTA: el unico check en rojo es el revisor automatico ({0}), y ya hay una revision real" -f ($failedChecks -join ', ')) -ForegroundColor DarkYellow
    Write-Host ("        registrada para este commit ({0}). Su pregunta -'alguien reviso esto?'- ya esta" -f ($evidence.reviewers -join ', ')) -ForegroundColor DarkGray
    Write-Host "        contestada, asi que deja de ser motivo de bloqueo." -ForegroundColor DarkGray
}

$blockers = @()
if (-not $checksOk) {
    $blockers += $(if ($ciTimedOut) { "checks de CI aun pendientes tras $CiTimeoutMinutes min (limite del gate, #562)" }
                   else             { "checks de CI fallando" })
}
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
        Write-Host "GATE SIN REVISAR - los checks estan en verde, pero NADIE reviso ESTE diff." -ForegroundColor Yellow
        if (-not "$($prState.headRefOid)".Trim()) {
            # Fail-closed, but say WHICH failure: blaming the user for not reviewing when the gate
            # could not even read the head commit would send them chasing the wrong thing.
            Write-Host "  No pude leer el commit actual del PR, asi que no puedo probar que ninguna" -ForegroundColor Yellow
            Write-Host "  revision corresponda a este codigo. Se rechaza por precaucion, no por falta de review." -ForegroundColor Yellow
        } elseif ($evidence.stale -gt 0) {
            Write-Host ("  Hay {0} revision(es) en el PR, pero de commits ANTERIORES - no cubren el codigo actual." -f $evidence.stale) -ForegroundColor Yellow
            Write-Host "  Empujaste cambios despues de que se reviso; esos cambios no los ha visto nadie." -ForegroundColor DarkGray
        } else {
            Write-Host "  0 reviews de GitHub y 0 revisiones externas registradas." -ForegroundColor Yellow
        }
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




