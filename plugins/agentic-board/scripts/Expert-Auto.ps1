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
    # "Llevalo de punta a punta" (#530): the human ORDERS this run to finish, so it may close CODE
    # work that carries a real review and recorded tests for the head commit. Not a stored setting --
    # the permission travels with the instruction and is good for this run only. Anything the owner
    # judges by looking at it still waits for him, ordered or not.
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
        # The owner ORDERED this run to finish (#530, reaching the brief since #536). Until now the
        # permission was recorded in the brake marker and never told to the agent that had to act
        # on it: the brief ordered the stop either way, so an ordered run obeyed a "stop" it had
        # been given while the "finish" sat in a file it never read. A switch, so an untaught
        # caller cannot grant it by accident.
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

    # The closing section. Ordered or not, the OTHER irreversible verbs stay off the table: the
    # end-to-end order is permission to finish THIS work, never a general lifting of the brake.
    $others = @($irr | Where-Object { "$_".Trim().ToLowerInvariant() -ne 'merge' })
    $othersList = if ($others.Count) { ($others -join ', ') } else { '(none)' }
    $closingSection = if ($EndToEnd) { @"
## Closing the work — ORDERED end to end (you MAY close this work yourself)

The owner ordered this run end to end, so you MAY close this work yourself — but only by EARNING
it. The merge gate re-checks all four conditions at merge time and will refuse if any is unmet:

1. ordered end to end        (given — that is why you are reading this)
2. the change is code        (a report, page, theme or image goes to the human, ordered or not)
3. a real review of THIS commit  (a green check is not a review)
4. automated tests ran on THIS commit  (recorded in CI, not in your own account of it)

Close it with ``Board-Merge.ps1``. That script IS the gate — it weighs the four conditions and
exits non-zero when they do not hold. Do NOT reach for ``gh pr merge`` or the REST merge endpoint:
they are refused at the tool layer, and going around the gate is not the same job as passing it.

If the gate refuses, it names exactly what is missing. Fix that and try again — do not look for
another way to merge.

STILL OFF LIMITS, ordered or not: $othersList. Those wait for the human.
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
    # ORDERED (#530/#536). Say what is actually true: the brake is still armed and still refuses
    # every ungated route; what the order opens is the GATED script, which re-checks the four
    # conditions and refuses on its own when they do not hold. Printing "will merge" here would
    # be the same overclaim #516 removed - the run has to earn it, and may well not.
    Write-Host "  Brake ARMED + END-TO-END ORDERED: the session may close its OWN PR, but only" -ForegroundColor Cyan
    Write-Host "               through Board-Merge.ps1, and only if the change is code, carries a" -ForegroundColor Cyan
    Write-Host "               real review of the head commit and CI passed on it. Otherwise it" -ForegroundColor Cyan
    Write-Host "               refuses and the PR waits for you. Deploy/publish/refresh/delete" -ForegroundColor Cyan
    Write-Host "               stay off the table." -ForegroundColor Cyan
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
    if ($EndToEnd) {
        Write-Host "  recorded evidence, self-drive the board, and close its own PR through the gate" -ForegroundColor DarkGray
        Write-Host "  if — and only if — it earns all four conditions." -ForegroundColor DarkGray
    } else {
        Write-Host "  recorded evidence, self-drive the board, and STOP at 'PR ready' before merge." -ForegroundColor DarkGray
    }
}
Write-Host ""
Write-Host "  Monitor:  scripts/Board-Work.ps1 -Sessions -Watch" -ForegroundColor Cyan
if ($ProjectNum -gt 0) {
    $owner = if ($repo) { ($repo -split '/')[0] } else { 'CSalcedoDataBI' }
    Write-Host ""
    Write-Host "Board: https://github.com/users/$owner/projects/$ProjectNum" -ForegroundColor Cyan
}

