<#
.SYNOPSIS
    /board expert `auto` — compose the autonomous brief and launch the auto-expert run.

.DESCRIPTION
    Reads the contract, pulls the issue/epic (its enriched plan), composes the autonomous brief
    (role objective + plan + definition-of-done + the capability map + the irreversible line), and
    launches a dedicated session in an isolated worktree — reusing the existing fleet/-Launch +
    worktree machinery. The user is freed and monitors with `/board work -Sessions -Watch`.

    Pure cores (Format-AutoBrief, Get-ContractBudgetMinutes) behind $env:ABIOS_EXPERTAUTO_DOTSOURCE
    for unit tests; the CLI half reads gh + the contract and drives the launch. The contract's
    time budget is ENFORCED (#564): it travels in the brake marker and the PreToolUse hook refuses
    non-wrap-up commands once it is spent.

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
    # The epic walker (#566): dispatch the NEXT READY WAVE of this epic's sub-issues - open, no
    # PR yet, no open blockers - one autonomous session each, brake+budget from the contract.
    # Idempotent: re-run it after merging a wave's PRs and it dispatches the next wave; done and
    # in-flight sub-issues are never re-dispatched. One command per WAVE instead of one human
    # launch per sub-issue.
    [int]$Epic = 0,
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
    # Presence, not truthiness: a cap of 0 means "create nothing" and is a legitimate contract.
    # `-and $...cap` would read 0 as absent and hand the run the default of 10 instead.
    $selfDriveCap = 10
    if ($Contract.boardSelfDrive -and $null -ne $Contract.boardSelfDrive.cap) { $selfDriveCap = [int]$Contract.boardSelfDrive.cap }
    # A role may name an agent definition; its persona is already folded into $RoleObjective,
    # and naming it here lets the launched run adopt it as its agent type too.
    $agentLine = if ($Contract.roleAgent) {
        "`nAdopt the agent type ``$($Contract.roleAgent)`` for this run — its definition is your persona.`n"
    } else { '' }

    # Say what is TRUE about the budget (round 7): a contract with maxMinutes 0 has enforcement
    # deliberately off, and briefing that run "the tool layer will refuse you" would be false
    # operator guidance - the same overclaim shape #516 removed from the brake.
    $budgetMin = Get-ContractBudgetMinutes -Contract $Contract
    $budgetSentence = if ($budgetMin -gt 0) {
        "The time budget ($budgetMin min) is ENFORCED, not advisory: past it, the tool layer refuses further work commands and only the wrap-up (handoff, commit/push WIP, report) still passes. When that happens, wrap up — do not fight the refusal."
    } else {
        "This contract sets no enforced time budget. Still hand off (``/board handoff -Save``) rather than grind when progress stalls."
    }

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
4. **Verify + evidence** — run the definition-of-done gates **that apply to your diff**: run
   ``Expert-WorkClass.ps1`` and it prints which of the contract's gates this change actually owes
   (a docs fix does not pay a model migration's toll; an unreadable diff owes every gate). Write
   a structured ``[abios-evidence]`` block to three places: the PR body, a durable issue comment,
   and ``evidence/<issue>.md``. If green -> open the PR + run the review gate.
5. **Self-heal + auto-drive the board**: when you hit an error, a fork, or an unexpected state —
   apply the **decision protocol** (research → register → decide); do NOT act first.
   Then act on what you decided: an in-scope problem → fix it in the loop and continue;
   an out-of-scope finding → file a sanitized 'discovered' issue on the board and keep going.
6. **Loop until done or budget**: keep iterating until the DoD is green — then leave the PR ready
   and STOP before merge — or the budget is spent -> ``/board handoff -Save``. $budgetSentence
7. **Report** — before you report anything, run ``/board expert verify`` for this issue and its PR.
   It reads the three evidence artifacts and answers COMPLETE or INCOMPLETE, naming what is missing.
   **Quote its verdict in your final report.** If it says INCOMPLETE you are not done: record what it
   names and run it again. Saying you recorded evidence is not the same as having recorded it — this
   check is the difference, and it is the one claim in your report you do not get to make yourself.

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

### Self-planning — escalating to an epic

When you discover the work is larger than the issue you were given, escalate rather than dropping
loose issues on the board with no parent. Use ``/board plan`` to create an epic + native
sub-issues — the same structure it builds for a human.

Bounds: the ``boardSelfDrive`` cap ($selfDriveCap) that governs ``discovered`` issues also caps the
sub-issues of any epic you create. Do not create more sub-issues than that limit.

Traceability: link the new epic to the originating issue (include the issue number,
e.g. ``Grew out of #<n>``, in the epic body) so the trail is followable.

## Test-first + evidence
Build test-first. After each verify phase, record a structured [abios-evidence] block (what was
tested, the command, the result) to the PR body, the issue comment, and evidence/<issue>.md.

$closingSection
"@
}

# Resolve the contract's time budget for the launch (#564). The old Get-BudgetVerdict computed a
# verdict NOTHING ever called - the 120-minute budget was a sentence in the brief and a runaway
# run had no wall-clock limit. Enforcement now lives where it can actually act: the launch writes
# budgetMinutes into the brake marker, and the PreToolUse hook (Brake-Guard.Get-BudgetState)
# refuses non-wrap-up commands once it is spent. Iterations stay advisory in the brief - a hook
# that sees single tool calls cannot count verify-loop iterations honestly, and pretending to
# would be the reporting-intent-as-fact defect again. Pure.
function Get-ContractBudgetMinutes {
    param([Parameter(Mandatory)][hashtable]$Contract)
    # Presence, not truthiness (external review, #564 round 1): a configured maxMinutes of 0 is a
    # deliberate "no budget enforcement" and must reach the marker as 0 - truthiness read it as
    # absent and silently re-armed the 120-minute default the owner had just switched off.
    $maxMin = 120
    $b = $Contract.budget
    if ($b) {
        $has = $false; $val = $null
        if ($b -is [hashtable]) {
            if ($b.ContainsKey('maxMinutes')) { $has = $true; $val = $b['maxMinutes'] }
        } elseif ($b.PSObject -and $b.PSObject.Properties['maxMinutes']) {
            $has = $true; $val = $b.PSObject.Properties['maxMinutes'].Value
        }
        if ($has) {
            # TryParse for EVERY shape (rounds 7/12): casts accept non-numbers (a boolean is
            # 1/0) and a JSON 2147483648 arrives as Int64 and overflows an [int] cast into a
            # crash at launch. Whatever does not parse as a plain Int32 means "malformed ->
            # default", never a crash and never "enforcement silently off".
            $parsed = 0
            if ([int]::TryParse("$val", [ref]$parsed)) { $maxMin = [Math]::Max(0, $parsed) }
        }
    }
    return $maxMin
}

<#
    Classify an epic's sub-issues into the NEXT dispatchable wave (#566).

    Nothing advanced an epic until now: Expert-Auto took one -Issue, so a plan with N sub-issues
    cost N human launches - Board-Plan even fetched the sub-issue list and threw it away. This is
    the walker's brain: given each sub-issue's state, its OPEN blockers and its linked-PR facts,
    split them into Done / InFlight (open PR - a session owns it) / Blocked (an open blocker) /
    Ready (dispatch now). The caller launches Ready and tells the human to re-run after merging.

    Fail direction: a sub-issue whose linked-work lookup FAILED (prKnown false) goes to InFlight,
    not Ready - dispatching a second session onto an issue that may already have one is the
    worse error. Pure.
#>
function Get-EpicWaveVerdict {
    param($SubIssues = @())
    $done = @(); $inFlight = @(); $blocked = @(); $ready = @()
    foreach ($s in @($SubIssues)) {
        if ($null -eq $s) { continue }
        if ("$($s.state)".ToUpperInvariant() -ne 'OPEN' -or [bool]$s.hasMergedPr) { $done += $s; continue }
        if (($null -ne $s.PSObject.Properties['prKnown']) -and -not [bool]$s.prKnown) { $inFlight += $s; continue }
        if ([bool]$s.hasOpenPr) { $inFlight += $s; continue }
        if (@($s.openBlockers).Count -gt 0) { $blocked += $s; continue }
        $ready += $s
    }
    return @{ Ready = @($ready); InFlight = @($inFlight); Blocked = @($blocked); Done = @($done) }
}

# Dot-source guard: tests set $env:ABIOS_EXPERTAUTO_DOTSOURCE to load the pure cores only.
if ($env:ABIOS_EXPERTAUTO_DOTSOURCE) { return }

# ── CLI ─────────────────────────────────────────────────────────────────────────
if ($Issue -le 0 -and $Epic -le 0) { throw "Expert-Auto: -Issue <n> or -Epic <n> is required." }
if ($Issue -gt 0 -and $Epic -gt 0) { throw "Expert-Auto: -Issue and -Epic are mutually exclusive - pick one." }

if (-not $env:GH_TOKEN) { $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User") }

# Resolve the contract (defaults if none configured yet).
$prevC = $env:ABIOS_EXPERTCONTRACT_DOTSOURCE
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = '1'
. (Join-Path $PSScriptRoot 'ExpertContractIo.ps1')
$env:ABIOS_EXPERTCONTRACT_DOTSOURCE = $prevC
$contract = Read-ExpertContract

# Pull the plan body from the issue (single-issue mode; the epic walker reads per sub-issue).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')
$repo = Get-RepoFromOriginUrl (git remote get-url origin 2>$null)
$planBody = ""
if ($repo -and $Issue -gt 0) {
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

# ── The epic walker (#566): dispatch the next ready wave, then hand back ────────
if ($Epic -gt 0) {
    if (-not $repo) { throw "Expert-Auto: no pude derivar el repo del origin - corre esto dentro del clon." }
    $rp = $repo -split '/'
    # The wave decision is driven by gh READS, so they go through the fail-closed wrapper
    # (external review round 2): raw `gh api graphql` exits 0 with an errors[] payload, and an
    # unread PR list dispatching a duplicate session is exactly the fail-open this walker bans.
    . (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

    # The epic and its NATIVE sub-issues. Both reads fail CLOSED: a wave dispatched from a
    # guessed list is exactly the reporting-intent-as-fact shape this tool keeps relearning.
    $epicJson = gh issue view $Epic --repo $repo --json title,body 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $epicJson) { throw "Expert-Auto: no pude leer el epic #$Epic en $repo." }
    $epicObj  = $epicJson | ConvertFrom-Json

    # Paginated (external review round 1): first:50 without pageInfo silently truncated a large
    # epic and could report it complete with open sub-issues still unread. Fail CLOSED per page.
    # The cursor travels as a -f VARIABLE, never spliced into the query text - PowerShell drops
    # embedded quotes passing args to gh.exe and an unquoted cursor breaks every paginated read
    # past 100 items (#329).
    $subs = @()
    $cursor = ''
    do {
        $ghArgs = @('api','graphql','-f','query=
query($o:String!,$r:String!,$n:Int!,$c:String){
  repository(owner:$o,name:$r){
    issue(number:$n){ subIssues(first:50, after:$c){
      pageInfo { hasNextPage endCursor }
      nodes { number title state repository { nameWithOwner } } } }
  }
}','-F',"o=$($rp[0])",'-F',"r=$($rp[1])",'-F',"n=$Epic")
        if ($cursor) { $ghArgs += @('-f',"c=$cursor") }
        # -Graphql throws on exit code OR errors[] - a partial list must never classify a wave.
        $pageData = Invoke-Gh -GhArgs $ghArgs -What "leer los sub-issues del epic #$Epic" -Graphql
        $page = $pageData.data.repository.issue.subIssues
        if ($null -eq $page -or $null -eq $page.pageInfo) { throw "Expert-Auto: respuesta sin subIssues para el epic #$Epic - no despacho sobre una lista a medias." }
        $subs += @($page.nodes | Where-Object { $_ })
        $cursor = if ($page.pageInfo.hasNextPage) { "$($page.pageInfo.endCursor)" } else { '' }
    } while ($cursor)
    if ($subs.Count -eq 0) { throw "Expert-Auto: el epic #$Epic no tiene sub-issues nativos - usa /board plan para crearlos, o -Issue para un issue suelto." }

    # Enrich each sub-issue with its OPEN blockers and its linked-PR facts. Blockers are
    # best-effort (the dependencies API may not exist for the account - degrade to unblocked,
    # same as Board-Work's own gate); the PR read fail-closes into prKnown=$false, which the
    # verdict routes to InFlight rather than Ready.
    # Cross-repo sub-issues are EXCLUDED with a warning (external review round 4): GitHub allows
    # them, and resolving their number against the epic's repo would brief and dispatch the
    # same-number issue in the WRONG repository. Walking a foreign repo is out of this walker's
    # scope - saying so beats guessing.
    $foreign = @($subs | Where-Object { "$($_.repository.nameWithOwner)" -and "$($_.repository.nameWithOwner)" -ne $repo })
    foreach ($f in $foreign) {
        Write-Host ("  WARN sub-issue #{0} vive en {1} (otro repo) - el caminante no lo despacha; trabajalo alla." -f $f.number, $f.repository.nameWithOwner) -ForegroundColor DarkYellow
    }
    $subs = @($subs | Where-Object { -not "$($_.repository.nameWithOwner)" -or "$($_.repository.nameWithOwner)" -eq $repo })

    $enriched = @()
    foreach ($s in $subs) {
        $openBlockers = @()
        try {
            $deps = gh api "repos/$repo/issues/$($s.number)/dependencies/blocked_by" 2>$null | ConvertFrom-Json
            if ($LASTEXITCODE -eq 0) {
                $openBlockers = @($deps | Where-Object { $_.state -eq 'open' } | ForEach-Object { [int]$_.number })
            }
        } catch { }
        $hasOpen = $false; $hasMerged = $false; $prKnown = $false
        try {
            # Through the wrapper (round 2): an errors[] payload with exit 0 must land in the
            # catch -> prKnown=$false -> InFlight, never in "no PRs" -> Ready.
            $lw = Invoke-Gh -GhArgs @('api','graphql','-f','query=
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    issue(number:$n){ closedByPullRequestsReferences(first:50, includeClosedPrs:true){
      pageInfo { hasNextPage }
      nodes { number state } } }
  }
}','-F',"o=$($rp[0])",'-F',"r=$($rp[1])",'-F',"n=$($s.number)") -What "leer los PRs del sub-issue #$($s.number)" -Graphql
            $issueNode = $lw.data.repository.issue
            if ($null -eq $issueNode) { throw "sin nodo issue" }
            # Another page = facts we did not see (round 3): an OPEN PR could hide there, so the
            # state is UNKNOWN -> InFlight, same fail direction as an unreadable list.
            if ($issueNode.closedByPullRequestsReferences.pageInfo.hasNextPage) { throw "mas de 50 PRs vinculados - estado no verificable" }
            $prs = @($issueNode.closedByPullRequestsReferences.nodes | Where-Object { $_ })
            $hasOpen   = [bool]($prs | Where-Object { $_.state -eq 'OPEN' })
            $hasMerged = [bool]($prs | Where-Object { $_.state -eq 'MERGED' })
            $prKnown   = $true
        } catch { $prKnown = $false }
        $enriched += [pscustomobject]@{
            number = [int]$s.number; title = "$($s.title)"; state = "$($s.state)"
            openBlockers = $openBlockers; hasOpenPr = $hasOpen; hasMergedPr = $hasMerged; prKnown = $prKnown
        }
    }

    $wave = Get-EpicWaveVerdict -SubIssues $enriched
    Write-Host "=== /board expert auto -Epic $Epic  ($($enriched.Count) sub-issues) ===" -ForegroundColor Cyan
    Write-Host ("  Done: {0}   In flight (PR abierto): {1}   Bloqueados: {2}   LISTOS: {3}" -f `
        @($wave.Done).Count, @($wave.InFlight).Count, @($wave.Blocked).Count, @($wave.Ready).Count) -ForegroundColor Cyan
    foreach ($s in @($wave.InFlight)) { Write-Host ("    ~ #{0} {1} (en vuelo)" -f $s.number, $s.title) -ForegroundColor DarkCyan }
    foreach ($s in @($wave.Blocked))  { Write-Host ("    x #{0} {1} (bloqueado por: {2})" -f $s.number, $s.title, (@($s.openBlockers) -join ', ')) -ForegroundColor DarkYellow }

    if (@($wave.Ready).Count -eq 0) {
        $openForeign = @($foreign | Where-Object { "$($_.state)".ToUpperInvariant() -eq 'OPEN' }).Count
        $openLeft = @($wave.InFlight).Count + @($wave.Blocked).Count + $openForeign
        if ($openLeft -eq 0) {
            Write-Host ""
            Write-Host "  EPIC COMPLETO: todos los sub-issues estan cerrados o mergeados. Cierra #$Epic si sigue abierto." -ForegroundColor Green
        } elseif ($openForeign -gt 0 -and (@($wave.InFlight).Count + @($wave.Blocked).Count) -eq 0) {
            # Round 5: an epic whose only open children live in ANOTHER repo is not complete -
            # it is simply outside this walker's reach, and saying "complete" would be false.
            Write-Host ""
            Write-Host ("  Sin trabajo local pendiente, pero {0} sub-issue(s) ABIERTOS viven en otro repo - el epic NO esta completo; trabajalos alla." -f $openForeign) -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host "  Nada listo para despachar: mergea los PRs en vuelo (el humano cierra cada ola) y re-ejecuta" -ForegroundColor Yellow
            Write-Host "  este mismo comando - la siguiente ola se despacha sola cuando sus bloqueadores cierren." -ForegroundColor Yellow
        }
        exit 0
    }

    $budgetMin = Get-ContractBudgetMinutes -Contract $contract
    . (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
    $stateDirEpic = Get-AbiosStateDir
    Write-Host ""
    Write-Host ("  Despachando la ola: {0}" -f ((@($wave.Ready) | ForEach-Object { "#$($_.number)" }) -join ', ')) -ForegroundColor Green
    foreach ($s in @($wave.Ready)) {
        # Per-issue brief: the epic's enriched plan + this sub-issue's own text. An unreadable
        # body SKIPS the dispatch (round 2): launching a session briefed with only a title is
        # sending it off half-blind, and the rest of the wave does not depend on this one.
        $subBody = $null
        $sj = gh issue view $s.number --repo $repo --json title,body 2>$null
        if ($LASTEXITCODE -eq 0 -and $sj) { try { $so = $sj | ConvertFrom-Json; $subBody = "$($so.body)" } catch { $subBody = $null } }
        if ($null -eq $subBody) {
            Write-Host ("  WARN #{0}: no pude leer el cuerpo del sub-issue - NO se despacha esta vez; re-ejecuta para reintentarlo." -f $s.number) -ForegroundColor DarkYellow
            continue
        }
        $wavePlan = "$($epicObj.title)`n`n$($epicObj.body)`n`n## Your sub-issue (deliver THIS, the epic above is context)`n#$($s.number) $($s.title)`n`n$subBody"
        $brief = Format-AutoBrief -Contract $contract -PlanBody $wavePlan -RoleObjective $contract.role -EndToEnd:$EndToEnd
        $briefPath = if ($stateDirEpic) { Join-Path $stateDirEpic "expert-brief-$($s.number).md" } else { "expert-brief-$($s.number).md" }
        $brief | Set-Content -Path $briefPath -Encoding utf8
        if ($DryRun) {
            Write-Host ("  [DryRun] #{0}: brief -> {1}; lanzaria Board-Work -Parallel {0} -Launch -StopAtPR:{2} -BudgetMinutes {3}" -f $s.number, $briefPath, $stopAtPR, $budgetMin) -ForegroundColor DarkYellow
        } else {
            # CHILD process, not in-process `&` (external review round 1): Board-Work's -Parallel
            # mode ends with `exit 0`, which in-process terminates THIS walker after the first
            # launch and silently drops the rest of the wave. Invoked via -Command, not -File:
            # -File flattens array arguments (the '129,130'->'129130' defect, PR #131), and a
            # flattened -Irreversible list would arm a brake whose vocabulary matches nothing.
            # Single-quoted values with doubled quotes so paths survive verbatim. A launch
            # failure warns and the wave continues - the sub-issues are independent.
            $sq = { param($v) "'" + ("$v" -replace "'", "''") + "'" }
            $irrLiteral = (@($contract.autonomy.irreversible) | ForEach-Object { & $sq $_ }) -join ','
            if (-not $irrLiteral) { $irrLiteral = "" }
            $bwCmd = "& $(& $sq (Join-Path $PSScriptRoot 'Board-Work.ps1')) -ProjectNum $ProjectNum -Parallel $($s.number) -Launch " +
                     "-TokenVar $(& $sq $TokenVar) -BriefFile $(& $sq $briefPath) -BudgetMinutes $budgetMin " +
                     "-Irreversible @($irrLiteral)" +
                     $(if ($stopAtPR) { ' -StopAtPR' } else { '' }) +
                     $(if ($EndToEnd) { ' -EndToEnd' } else { '' })
            & pwsh -NoProfile -Command $bwCmd
            if ($LASTEXITCODE -ne 0) {
                Write-Host ("  WARN #{0}: el lanzamiento devolvio {1} - revisa arriba; la ola continua." -f $s.number, $LASTEXITCODE) -ForegroundColor DarkYellow
            }
        }
    }
    Write-Host ""
    Write-Host "  Ola despachada. Cuando sus PRs esten mergeados, re-ejecuta:" -ForegroundColor Cyan
    Write-Host "    /board expert auto -Epic $Epic     (despacha la siguiente ola; es idempotente)" -ForegroundColor Cyan
    Write-Host "  Monitor: scripts/Board-Work.ps1 -Sessions -Watch (el supervisor publica [abios-stall] solo)." -ForegroundColor DarkGray
    exit 0
}

# Persist the brief so the launched session can read it.
. (Join-Path $PSScriptRoot 'Get-AbiosStateDir.ps1')
$stateDir = Get-AbiosStateDir
$briefPath = if ($stateDir) { Join-Path $stateDir "expert-brief-$Issue.md" } else { "expert-brief-$Issue.md" }
$brief | Set-Content -Path $briefPath -Encoding utf8

Write-Host "=== /board expert auto  (issue #$Issue) ===" -ForegroundColor Cyan
Write-Host "  Brief composed -> $briefPath" -ForegroundColor Green
Write-Host "  Autonomy brakes only on: $($contract.autonomy.irreversible -join ', ')" -ForegroundColor DarkGray
$resolvedBudget = Get-ContractBudgetMinutes -Contract $contract
if ($resolvedBudget -gt 0) {
    Write-Host "  Time budget: $resolvedBudget min - ENFORCED by the PreToolUse hook (#564): past it, only wrap-up commands pass." -ForegroundColor DarkGray
} else {
    # Say what is true (round 8): a 0 budget is enforcement deliberately OFF, and printing
    # "ENFORCED" for it is the same overclaim shape the brake messages were cured of (#516).
    Write-Host "  Time budget: NONE - this contract sets maxMinutes 0, so no mechanical limit is armed (#564)." -ForegroundColor DarkYellow
}
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
        -StopAtPR:$stopAtPR -BriefFile $briefPath -Irreversible @($contract.autonomy.irreversible) -EndToEnd:$EndToEnd `
        -BudgetMinutes (Get-ContractBudgetMinutes -Contract $contract)
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


