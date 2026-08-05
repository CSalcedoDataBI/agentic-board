<#
.SYNOPSIS
    Break a large issue into native sub-issues (/board work breakdown).

.DESCRIPTION
    GitHub best practice: break large issues into smaller ones so work is
    manageable and PRs stay small. This script creates one child issue per
    task title and attaches each to the parent as a NATIVE sub-issue
    (GraphQL addSubIssue), which makes the board's "Sub-issues progress"
    column fill itself as children close.

    Children get the 'task' label (created if missing) and a body that
    links back to the parent. If the repo has an auto-add CI workflow
    (/board automate), the children land on the board automatically.

    Use a task LIST in the parent body instead (checkboxes) when the pieces
    are too small to deserve their own issue - this script is for
    substantial children only.

.PARAMETER Parent
    Parent issue number. Mandatory.

.PARAMETER Tasks
    One or more child issue titles. Mandatory.

.PARAMETER Repo
    owner/name. Default: derived from the current directory's origin remote.

.PARAMETER Label
    Label for the children (created if missing). Default: task.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Board-Breakdown.ps1 -Parent 47 -Tasks "Part A - schema reader", "Part B - diff engine"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Parent,
    [Parameter(Mandatory)][string[]]$Tasks,
    [string]$Repo = "",
    [string]$Label = "task",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

# ── Top-level error boundary (#485): any unhandled exception becomes a clean
# one-line message on stdout so the caller always sees what failed — never a
# silent exit 1 or a raw PowerShell stack dump going to stderr only.
trap {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# The single resolver for owner/name from this clone's origin (#281). Do NOT inline the regex
# again: the copy-pasted version ate any dot in the repo name (midominio.com -> midominio).
. (Join-Path $PSScriptRoot 'Get-RepoFromOrigin.ps1')

# gh api graphql can return exit 0 with an errors[] body: addSubIssue would then report a linked
# child that is actually loose. -Graphql fails closed on that AND on a plain non-zero exit (#303).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

if (-not $Repo) {
    $originUrl = git remote get-url origin 2>$null
    $Repo = Get-RepoFromOriginUrl $originUrl
}
if (-not $Repo) { throw "No pude derivar el repo del origin - pasa -Repo owner/name." }

# Parent must exist and be open. A failed read here would leave $parentId empty and every
# addSubIssue below would orphan its child - so fail closed on the read (#303).
$parentData = Invoke-Gh -GhArgs @('issue','view',"$Parent",'--repo',$Repo,'--json','id,title,state') `
                        -What "leer el issue padre #$Parent" -Json
if ($parentData.state -eq "CLOSED") { throw "El issue padre #$Parent esta CERRADO - reabrelo antes de desglosarlo." }
$parentId    = $parentData.id
$parentTitle = $parentData.title

Write-Host "=== Board-Breakdown  #$Parent '$parentTitle'  ->  $($Tasks.Count) sub-issue(s) ===" -ForegroundColor Cyan
Write-Host ""

# Label must exist or gh issue create fails
gh label create $Label --color 0e8a16 --description "Concrete work item with a definition of done" --force --repo $Repo 2>&1 | Out-Null

$created = @(); $fail = 0
foreach ($t in $Tasks) {
    try {
        $body = "Part of #${Parent}: $parentTitle"
        # A FAILING NATIVE COMMAND DOES NOT THROW - not even under $ErrorActionPreference='Stop'.
        # So the catch below never fired: gh 404'd, $url came back empty, `[int]''` quietly
        # produced 0, and every task printed "OK #0" with "fallos: 0" while NOTHING was created
        # (#281). Check $LASTEXITCODE after each gh call, and treat a non-positive issue number
        # as the failure it is - #0 was always the tell.
        $url = gh issue create --repo $Repo --title $t --body $body --label $Label
        if ($LASTEXITCODE -ne 0) { throw "gh issue create fallo (exit $LASTEXITCODE)" }
        $num = Get-IssueNumberFromUrl $url
        if ($num -le 0) { throw "no pude leer el numero del issue creado (gh devolvio '$url')" }

        $childId = gh issue view $num --repo $Repo --json id -q .id
        if ($LASTEXITCODE -ne 0 -or -not $childId) { throw "gh issue view #$num fallo (exit $LASTEXITCODE)" }

        # addSubIssue can 200 with an errors[] body (already-linked, permissions) - -Graphql throws
        # on that as well as on a non-zero exit, so a loose child is never listed as linked.
        $linkQuery = '
mutation($p:ID!, $c:ID!) {
  addSubIssue(input:{issueId:$p, subIssueId:$c}) { issue { number } }
}'
        try {
            $null = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$linkQuery",'-f',"p=$parentId",'-f',"c=$childId") `
                              -What "enlazar #$num como sub-issue de #$Parent" -Graphql
        } catch {
            # The issue exists but is not linked - say so instead of silently listing it as a child.
            throw "#$num se creo pero addSubIssue fallo ($($_.Exception.Message)) - queda suelto, enlazalo a mano"
        }

        Write-Host "  OK  #$num  $t" -ForegroundColor Green
        $created += $num
    } catch {
        Write-Host "  FAIL '$t': $_" -ForegroundColor Red
        $fail++
    }
}

Write-Host ""
Write-Host "Sub-issues creados: $($created.Count)  fallos: $fail" -ForegroundColor Cyan
Write-Host "La columna 'Sub-issues progress' del board se llena sola al cerrarlos." -ForegroundColor DarkGray
Write-Host "Empieza uno con: Board-Work.ps1 -ProjectNum <n> -Start <num> -Branch" -ForegroundColor Cyan
