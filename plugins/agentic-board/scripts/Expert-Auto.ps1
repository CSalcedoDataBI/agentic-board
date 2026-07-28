<#
.SYNOPSIS
    /board expert `auto` — compose the autonomous brief and launch the auto-expert run.

.DESCRIPTION
    Reads the contract, pulls the issue/epic (its enriched plan), composes the autonomous brief
    (role objective + plan + definition-of-done + the capability map + the irreversible line), and
    launches a dedicated session in an isolated worktree — reusing the existing fleet/-Launch +
    worktree machinery. The user is freed and monitors with `/board work -Sessions -Watch`.

    Pure cores (Format-AutoBrief, Get-BudgetVerdict, Test-GhScope, Assert-BrakeCompliance,
    Format-ComplianceReport) behind $env:ABIOS_EXPERTAUTO_DOTSOURCE for unit tests; the CLI half
    reads gh + the contract and drives the launch.

    Autonomy brakes only on the irreversible (Expert-Autonomy): the run reaches "PR ready" and
    stops there for the human to merge.

    Launch-time guards (#440):
    - Token scope: only overrides the ambient gh login with the registry PAT when the ambient
      login lacks 'project' scope; if neither has it, warns with a recovery command.
    - Stale HEAD: after fetching, warns when the local default branch is behind origin so the
      human knows their local view is stale (the worktree is still cut from origin/<default>).

    Post-run compliance (#440): the brief embeds the main SHA at launch time and instructs the
    session to compare it before recording Fleet-Findings, writing a PASS/VIOLATION verdict as
    an [abios-evidence] comment.

.PARAMETER Issue
    The issue/epic number to execute.

.PARAMETER ProjectNum
    The board number (for status + monitoring).

.PARAMETER DryRun
    Compose + persist the brief and print the plan without spawning anything.

.EXAMPLE
    .\Expert-Auto.ps1 -Issue 123 -ProjectNum 13
#>
[CmdletBinding()]
param(
    [int]$Issue = 0,
    [int]$ProjectNum = 0,
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

function Format-AutoBrief {
    param(
        [Parameter(Mandatory)][hashtable]$Contract,
        [string]$PlanBody = "",
        [string]$RoleObjective = "",
        [string]$MainShaAtLaunch = "",  # embed compliance checkpoint when provided (#440)
        [string]$Repo = "",             # owner/name used in the compliance check command
        [int]$IssueNum = 0              # target issue for the [abios-evidence] verdict
    )
    $dod = @()
    if ($Contract.dod) { $dod = @($Contract.dod.Keys | Where-Object { $Contract.dod[$_] }) }
    $dodList = if ($dod.Count) { ($dod | ForEach-Object { "- $_" }) -join "`n" } else { "- (none specified)" }
    $irr = @()
    if ($Contract.autonomy -and $Contract.autonomy.irreversible) { $irr = @($Contract.autonomy.irreversible) }
    $irrList = ($irr -join ', ')
    # A role may name an agent definition; its persona is already folded into $RoleObjective,
    # and naming it here lets the launched run adopt it as its agent type too.
    $agentLine = if ($Contract.roleAgent) {
        "`nAdopt the agent type ``$($Contract.roleAgent)`` for this run — its definition is your persona.`n"
    } else { '' }

    # Compliance checkpoint embeds the main SHA recorded at launch (#440 problem 2).
    # The session compares the current SHA against it to detect any unauthorized merge.
    $complianceSection = if ($MainShaAtLaunch) {
        $repoClause   = if ($Repo)     { " in $Repo" } else { "" }
        $issueClause  = if ($IssueNum) { " #$IssueNum" } else { "" }
        $checkCmd     = if ($Repo)     { "``gh api repos/$Repo/branches/main -q '.commit.sha'``" } else { "``git rev-parse origin/HEAD``" }
        @"


## Compliance check (do this BEFORE Fleet-Findings — non-negotiable)
The main branch SHA at launch was: ``$MainShaAtLaunch``
Before recording your findings, verify the irreversible brake held:
1. Fetch the current default-branch SHA: $checkCmd
2. Compare to the launch SHA above.
3. If they differ, the brake was violated (main was merged to). Post an [abios-evidence] VIOLATION
   comment to issue$issueClause$repoClause.
4. If they match, post an [abios-evidence] PASS comment to the same issue.
Either way, the verdict comment must appear before you record Fleet-Findings.
"@
    } else { '' }

    @"
# Autonomous brief — /board expert auto

$RoleObjective
$agentLine

## Plan (what to deliver)
$PlanBody

## Definition of Done — every gate must pass before you consider this complete
$dodList

## How you work — total self-use of agentic-board (do NOT improvise your own tooling)
- Research / prior-art -> /knowledge add + /knowledge harvest
- Acquire / verify skills -> /skills bootstrap, /skills audit
- Discover latent work -> /scan
- Record work / findings -> /board issue, /board plan, /board triage
- Report progress / evidence -> /board update, [abios-evidence] comment
- Survive budget / interruption -> /board handoff -Save

## Test-first + evidence
Build test-first. After each verify phase, record a structured [abios-evidence] block (what was
tested, the command, the result) to the PR body, the issue comment, and evidence/<issue>.md.

## Self-heal
An in-scope problem: fix it in the loop and continue. An out-of-scope finding (side bug, debt):
file a sanitized 'discovered' issue on the board and keep going — never block on it.
$complianceSection
## STOP before the irreversible (brake — ask the human)
STOP before: $irrList.
Reach "PR ready + review gate green" and STOP there. Do NOT merge, deploy, refresh, publish, or
delete on your own.
"@
}

# ── Pure core: token scope check (#440 footgun 1) ───────────────────────────────

# Returns $true when the output of 'gh auth status' lists the given scope.
# $StatusText is injected in tests so no real gh call is needed.
function Test-GhScope {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [string]$StatusText = ""
    )
    if ($StatusText -match "(?i)Token scopes:\s*(.+)") {
        $scopes = $Matches[1] -split ',\s*' | ForEach-Object { $_.Trim().Trim("'") }
        return [bool]($scopes -contains $Scope)
    }
    return $false
}

# ── Pure core: post-run compliance check (#440 problem 2) ───────────────────────

# Compare the main SHA recorded at launch to the current SHA.
# Returns @{ compliant=$bool; mainMoved=$bool; detail='' }.
# $mergeIsIrreversible is derived from the contract inside the function so the
# logic stays testable without wiring a full contract every time.
function Assert-BrakeCompliance {
    param(
        [Parameter(Mandatory)][hashtable]$Contract,
        [Parameter(Mandatory)][string]$CurrentMainSha,
        [Parameter(Mandatory)][string]$MainShaAtLaunch
    )
    $mergeIsIrreversible = $false
    if ($Contract.autonomy -and $Contract.autonomy.irreversible) {
        $irr = @($Contract.autonomy.irreversible | ForEach-Object { "$_".ToLowerInvariant() })
        $mergeIsIrreversible = $irr -contains 'merge'
    }
    $mainMoved = ($CurrentMainSha -ne $MainShaAtLaunch) -and
                 ($CurrentMainSha -ne '') -and ($MainShaAtLaunch -ne '')
    $violated  = $mainMoved -and $mergeIsIrreversible
    $shortLaunch  = if ($MainShaAtLaunch.Length  -ge 7) { $MainShaAtLaunch.Substring(0,7)  } else { $MainShaAtLaunch }
    $shortCurrent = if ($CurrentMainSha.Length -ge 7) { $CurrentMainSha.Substring(0,7) } else { $CurrentMainSha }
    $detail = if ($mainMoved) { "main moved: $shortLaunch -> $shortCurrent" } else { "main SHA unchanged ($shortLaunch)" }
    return @{
        compliant = -not $violated
        mainMoved = $mainMoved
        detail    = $detail
    }
}

# Format the compliance result as an [abios-evidence] block.
function Format-ComplianceReport {
    param(
        [Parameter(Mandatory)][hashtable]$Compliance,
        [int]$Issue = 0
    )
    $verdict = if ($Compliance.compliant) { 'PASS' } else { 'FAIL (BRAKE VIOLATED)' }
    $icon    = if ($Compliance.compliant) { '[OK]' } else { '[VIOLATION]' }
    $issueTag = if ($Issue -gt 0) { " #$Issue" } else { "" }
    @"
<!-- [abios-evidence] -->
## Compliance report — /board expert auto$issueTag

**Verdict:** $icon $verdict

| Check | Result |
| --- | --- |
| main moved? | $($Compliance.mainMoved) |
| detail | $($Compliance.detail) |
"@
}

function Get-BudgetVerdict {
    param(
        [Parameter(Mandatory)][int]$ElapsedMinutes,
        [Parameter(Mandatory)][int]$Iterations,
        [Parameter(Mandatory)][hashtable]$Contract
    )
    $maxMin = 120; $maxIter = 8
    if ($Contract.budget) {
        if ($Contract.budget.maxMinutes)    { $maxMin  = [int]$Contract.budget.maxMinutes }
        if ($Contract.budget.maxIterations) { $maxIter = [int]$Contract.budget.maxIterations }
    }
    if ($ElapsedMinutes -gt $maxMin) { return 'handoff' }
    if ($Iterations -ge $maxIter)    { return 'handoff' }
    'continue'
}

# Dot-source guard: tests set $env:ABIOS_EXPERTAUTO_DOTSOURCE to load the pure cores only.
if ($env:ABIOS_EXPERTAUTO_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
if ($Issue -le 0) { throw "Expert-Auto: -Issue <n> is required." }

# ── Token scope guard (#440 footgun 1) ──────────────────────────────────────────
# Prefer the ambient gh login when it has 'project' scope; only fall back to the
# registry PAT when the ambient login is unscoped or unauthenticated. Setting
# GH_TOKEN overrides gh's own session — if the registry PAT has fewer scopes, every
# board operation inside the launched run fails with INSUFFICIENT_SCOPES.
if (-not $env:GH_TOKEN) {
    $ghStatus         = gh auth status 2>&1 | Out-String
    $ambientOk        = Test-GhScope -Scope 'project' -StatusText $ghStatus
    $registryToken    = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
    if ($ambientOk) {
        Write-Host "  Token: ambient gh login has 'project' scope — leaving GH_TOKEN unset." -ForegroundColor DarkGray
    } elseif ($registryToken) {
        $env:GH_TOKEN = $registryToken
        Write-Host "  Token: set from registry ($TokenVar) — ambient gh login lacks 'project' scope." -ForegroundColor DarkGray
    } else {
        Write-Warning "No GH_TOKEN set and ambient gh login lacks 'project' scope. Board operations may fail with INSUFFICIENT_SCOPES. Run 'gh auth refresh -s project' or set $TokenVar with 'project' scope."
    }
}

# Resolve the contract (defaults if none configured yet).
$prevC = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC
$contract = Read-ExpertContract

# Pull the plan body from the issue.
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
$repo = Get-RepoFromOriginUrl (git remote get-url origin 2>$null)
$planBody = ""
if ($repo) {
    $json = gh issue view $Issue --repo $repo --json title,body 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) {
        try { $o = $json | ConvertFrom-Json; $planBody = "$($o.title)`n`n$($o.body)" } catch { }
    }
}

# ── Stale HEAD guard (#440 footgun 2) ───────────────────────────────────────────
# Fetch so the worktree is cut from a fresh origin/<default>.  Also warn when the
# local default branch is behind its remote — the worktree base is safe (it comes
# from origin/<default>), but a stale local clone hides recent context from the human.
git fetch origin --quiet 2>$null | Out-Null
$mainShaAtLaunch = ""
$localDefaultSha = $remoteSha = ""
$originHead = git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $originHead) {
    $localBranch     = $originHead -replace '^origin/', ''
    $localDefaultSha = git rev-parse --quiet $localBranch 2>$null
    $remoteSha       = git rev-parse --quiet $originHead  2>$null
    $mainShaAtLaunch = if ($LASTEXITCODE -eq 0 -and $remoteSha) { $remoteSha } else { "" }
    if ($localDefaultSha -and $remoteSha -and $localDefaultSha -ne $remoteSha) {
        $short = if ($remoteSha.Length -ge 7) { $remoteSha.Substring(0,7) } else { $remoteSha }
        Write-Warning "Local '$localBranch' is behind '$originHead' ($short). The worktree will be cut from '$originHead' (safe), but sync with 'git pull' when convenient."
    }
}

$brief = Format-AutoBrief -Contract $contract -PlanBody $planBody -RoleObjective $contract.role `
    -MainShaAtLaunch $mainShaAtLaunch -Repo $repo -IssueNum $Issue

# The brake, as a CONTROL rather than prose (#440). The generic launch briefing used to order
# the merge outright and make it the completion condition, so a session that merged to main was
# obeying its brief while this file's "STOP before merge" sat in a document nobody handed it.
# Ask the same gate the expert uses at runtime, then thread the answer into the launcher.
$prevA = $env:ABIOS_EXPERTAUTONOMY_DOTSOURCE
$env:ABIOS_EXPERTAUTONOMY_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'Expert-Autonomy.ps1')
$env:ABIOS_EXPERTAUTONOMY_DOTSOURCE = $prevA
$stopAtPR = Test-IsIrreversible -Action 'merge' -Contract $contract

# Persist the brief so the launched session can read it.
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
$stateDir = Get-AbiosStateDir
$briefPath = if ($stateDir) { Join-Path $stateDir "expert-brief-$Issue.md" } else { "expert-brief-$Issue.md" }
$brief | Set-Content -Path $briefPath -Encoding utf8

Write-Host "=== /board expert auto  (issue #$Issue) ===" -ForegroundColor Cyan
Write-Host "  Brief composed -> $briefPath" -ForegroundColor Green
Write-Host "  Autonomy brakes only on: $($contract.autonomy.irreversible -join ', ')" -ForegroundColor DarkGray
if ($stopAtPR) {
    Write-Host "  Brake ARMED: the launched session is briefed to stop at a reviewed PR (no merge step)." -ForegroundColor Green
} else {
    Write-Host "  Brake OFF: 'merge' is not irreversible in this contract - the session WILL merge its own PR." -ForegroundColor Yellow
}
Write-Host ""

$launchArgs = "-ProjectNum $ProjectNum -Parallel $Issue -Launch" + $(if ($stopAtPR) { " -StopAtPR -BriefFile `"$briefPath`"" } else { "" })
if ($DryRun) {
    Write-Host "  [DryRun] would launch a dedicated session in a worktree off origin/main and monitor it." -ForegroundColor DarkYellow
    Write-Host "  Launch:  scripts/Board-Work.ps1 $launchArgs" -ForegroundColor DarkGray
} else {
    Write-Host "  Launching the autonomous session in an isolated worktree..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Board-Work.ps1') -ProjectNum $ProjectNum -Parallel $Issue -Launch -TokenVar $TokenVar `
        -StopAtPR:$stopAtPR -BriefFile $briefPath
    Write-Host ""
    Write-Host "  The launched session is briefed by $briefPath — it will research, build, test with" -ForegroundColor DarkGray
    Write-Host "  recorded evidence, self-drive the board, and STOP at 'PR ready' before merge." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Monitor:  scripts/Board-Work.ps1 -Sessions -Watch" -ForegroundColor Cyan
if ($ProjectNum -gt 0) {
    $owner = if ($repo) { ($repo -split '/')[0] } else { 'CSalcedoDataBI' }
    Write-Host ""
    Write-Host "Board: https://github.com/users/$owner/projects/$ProjectNum" -ForegroundColor Cyan
}
