<#
.SYNOPSIS
    /board expert `auto` — compose the autonomous brief and launch the auto-expert run.

.DESCRIPTION
    Reads the contract, pulls the issue/epic (its enriched plan), composes the autonomous brief
    (role objective + plan + definition-of-done + the capability map + the irreversible line), and
    launches a dedicated session in an isolated worktree — reusing the existing fleet/-Launch +
    worktree machinery. The user is freed and monitors with `/board work -Sessions -Watch`.

    Pure cores (Format-AutoBrief, Get-BudgetVerdict) behind $env:ABIOS_EXPERTAUTO_DOTSOURCE for
    unit tests; the CLI half reads gh + the contract and drives the launch.

    Autonomy brakes only on the irreversible (Expert-Autonomy): the run reaches "PR ready" and
    stops there for the human to merge.

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
    # "Llevalo de punta a punta" (#530): the human ORDERS this run to finish. RECORDED, NOT
    # HONOURED (#541) - it is written into the brake marker and explained to the launched session,
    # and no merge route is opened for it. Still pass it when the human says it: a run that knows
    # the order exists and is inert reads its refusal as the control working, instead of hunting
    # for a way around it. Never tell the user the run will merge.
    [switch]$EndToEnd,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ── Pure core ───────────────────────────────────────────────────────────────────

function Format-AutoBrief {
    param(
        [Parameter(Mandatory)][hashtable]$Contract,
        [string]$PlanBody = "",
        [string]$RoleObjective = "",
        # The owner ORDERED this run to finish (#530). The brief now EXPLAINS that order rather than
        # granting it: the mechanism that would honour it was found to have two holes it could not
        # defend (#541), so the run is told plainly that the order is recorded, cannot yet be acted
        # on, and that a refused merge is the control working - not a bug to route around. Telling
        # it nothing would leave it reading its own refusal as failure.
        [switch]$EndToEnd
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

    # The closing section. Both branches STOP; the ordered one also says why the order is inert.
    $closingSection = if ($EndToEnd) { @"
## STOP before the irreversible — including the close you were ordered to make

The owner ordered this run end to end, and that order is RECORDED in your brake marker. It is not
yet something you can act on, and you should not try.

Why, stated plainly so you do not treat the refusal as a bug: the mechanism that would let an
ordered run close its own PR was found to have two holes it could not defend (#541). Changing
directory before invoking the gate made the gate skip its own checks entirely, and the "a real
review exists" condition was satisfied by a PR comment the run itself can post. Until both are
closed, the tool layer refuses every merge route for every run, ordered or not.

So: reach "PR ready + review gate green" and STOP there, exactly as an unordered run would. Do NOT
merge, deploy, refresh, publish or delete. If a merge command is refused, that is this control
working as intended — do not look for another way around it. Say in your final report that the
work is ready and the close is waiting for the human.

STOP before: $irrList.
"@ } else { @"
## STOP before the irreversible (brake — ask the human)
STOP before: $irrList.
Reach "PR ready + review gate green" and STOP there. Do NOT merge, deploy, refresh, publish, or
delete on your own.
"@ }

    @"
# Autonomous brief — /board expert auto

$RoleObjective
$agentLine

## Plan (what to deliver)
$PlanBody

## Definition of Done — every gate must pass before you consider this complete
$dodList

## How you work — seven phases (do NOT skip any)

Work sequentially through these seven phases. A capability list alone is not a method; the phases
are the method.

1. **Ingest** — read the epic/issue and its enriched plan (Role, Deliverables, Test plan / DoD).
2. **Become the expert** — adopt the role objective. Research prior-art and docs, and register
   findings via ``/knowledge add`` / ``/knowledge harvest`` (read-and-forget is not allowed).
   Acquire missing tooling via ``/skills bootstrap`` / ``/skills audit``.
3. **Execute (test-first)** — build guided by tests first, in the worktree.
4. **Verify + evidence** — run the definition-of-done gates. Write a structured ``[abios-evidence]``
   block to three places: the PR body, a durable issue comment, and ``evidence/<issue>.md``.
   If green -> open the PR + run the review gate.
5. **Self-heal + auto-drive the board**: in-scope problem -> fix it (after researching first);
   out-of-scope finding -> file a sanitized 'discovered' issue on the board and keep going.
6. **Loop until done or budget**: keep iterating until the DoD is green — then leave the PR ready
   and STOP before merge — or the budget is spent -> ``/board handoff -Save``.
7. **Report** — final evidence + updated board + a PR awaiting the human's merge approval.

### Decision protocol — research before deciding

When you hit an error, an unexpected state, or a fork in the path: **research before deciding —
do NOT act first.**

1. Research — check prior-art, existing patterns, similar resolved issues (``/knowledge``).
2. Register — log findings via ``/knowledge add`` / ``/knowledge harvest``. Read-and-forget is not research.
3. Decide — then choose the fix or path.

### Capability map — total self-use of agentic-board (do NOT improvise your own tooling)

Every need below already has a capability. Reach for it instead of inventing your own tooling.

- Research / prior-art -> ``/knowledge add`` + ``/knowledge harvest``
- Acquire / verify skills -> ``/skills bootstrap``, ``/skills audit``
- Discover latent work -> ``/scan``
- Record work / findings -> ``/board issue``, ``/board plan``, ``/board triage``
- Report progress / evidence -> ``/board update``, ``[abios-evidence]`` comment
- Survive budget / interruption -> ``/board handoff -Save``

## Test-first + evidence
Build test-first. After each verify phase, record a structured [abios-evidence] block (what was
tested, the command, the result) to the PR body, the issue comment, and evidence/<issue>.md.

$closingSection
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

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }

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

$brief = Format-AutoBrief -Contract $contract -PlanBody $planBody -RoleObjective $contract.role -EndToEnd:$EndToEnd

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
if ($stopAtPR -and $EndToEnd) {
    # Say what is TRUE, not what was asked for. The order is recorded and cannot yet be acted on
    # (#541); printing "the session may close its own PR" would be the same overclaim #516 removed.
    Write-Host "  Brake ARMED. The end-to-end order is RECORDED but NOT yet honoured:" -ForegroundColor Yellow
    Write-Host "               the mechanism that would let a run close its own PR was found to have" -ForegroundColor Yellow
    Write-Host "               two holes it could not defend (see issue #541), so every merge route" -ForegroundColor Yellow
    Write-Host "               is refused for every run. This session will stop at a reviewed PR and" -ForegroundColor Yellow
    Write-Host "               the close is yours." -ForegroundColor Yellow
} elseif ($stopAtPR) {
    # #516: this line used to claim a brake that was only a paragraph in the brief. It is now a
    # control - Start-WorktreeSession writes a marker into the worktree and a PreToolUse hook
    # refuses the irreversible call - so the claim is finally true. Keep the wording honest:
    # if the arming step fails, Start-WorktreeSession refuses to launch rather than print this.
    Write-Host "  Brake ARMED: the launched session is briefed to stop at a reviewed PR, AND a" -ForegroundColor Green
    Write-Host "               PreToolUse guard refuses the merge if it asks anyway." -ForegroundColor Green
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
        -StopAtPR:$stopAtPR -BriefFile $briefPath -Irreversible @($contract.autonomy.irreversible) -EndToEnd:$EndToEnd
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

