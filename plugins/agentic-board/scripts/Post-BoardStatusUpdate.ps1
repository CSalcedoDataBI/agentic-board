<#
.SYNOPSIS
    Post a status update on a GitHub Projects v2 board (/board update).

.DESCRIPTION
    GitHub Projects best practice: use status updates to share high-level
    progress. This script posts a ProjectV2 status update
    (createProjectV2StatusUpdate). With no -Body it generates one from the
    live board: counts per Status plus the next pending items by Priority.

.PARAMETER Owner
    GitHub username that owns the project. Defaults to CSalcedoDataBI.

.PARAMETER ProjectNum
    GitHub Projects v2 number. Mandatory.

.PARAMETER Status
    ON_TRACK (default) | AT_RISK | OFF_TRACK | COMPLETE | INACTIVE.

.PARAMETER Body
    Markdown body. Empty = auto-generated from the board.

.PARAMETER TokenVar
    Windows USER env var holding the PAT. Defaults to GITHUB_TOKEN_PERSONAL.

.EXAMPLE
    .\Post-BoardStatusUpdate.ps1 -ProjectNum 13
    .\Post-BoardStatusUpdate.ps1 -ProjectNum 13 -Status AT_RISK -Body "Blocked by X"
#>
[CmdletBinding()]
param(
    [string]$Owner = "CSalcedoDataBI",
    [Parameter(Mandatory)][int]$ProjectNum,
    [ValidateSet("ON_TRACK","AT_RISK","OFF_TRACK","COMPLETE","INACTIVE")]
    [string]$Status = "ON_TRACK",
    [string]$Body = "",
    [string]$TokenVar = "GITHUB_TOKEN_PERSONAL"
)

$ErrorActionPreference = "Stop"

if (-not $env:GH_TOKEN) {
    $env:GH_TOKEN = [System.Environment]::GetEnvironmentVariable($TokenVar, "User")
}
if (-not $env:GH_TOKEN) { throw "$TokenVar not set in Windows USER environment (and GH_TOKEN empty)." }

# gh api graphql can return exit 0 with an errors[] body, and gh signals a plain failure only via
# its exit code - either way an unchecked read here would post a status update off a misread board
# (a wrong "0 Done" body, or the mutation's own silent failure). -Graphql fails closed on both (#303).
. (Join-Path $PSScriptRoot 'Invoke-Gh.ps1')
# ...and a CAPPED read is the other half (#484): this body is PUBLISHED, so "0 Backlog" computed
# from a short list is a false public statement about the project's progress.
. (Join-Path $PSScriptRoot 'Get-BoardItems.ps1')

$boardUrl = "https://github.com/users/$Owner/projects/$ProjectNum"

# Resolve project id
$pidQuery = '
query($owner:String!, $num:Int!) {
  user(login:$owner) { projectV2(number:$num) { id title } }
}'
$projData = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$pidQuery",'-f',"owner=$Owner",'-F',"num=$ProjectNum") `
                      -What "leer el board #$ProjectNum" -Graphql
$projectId = $projData.data.user.projectV2.id
if (-not $projectId) { throw "Board #$ProjectNum no encontrado para $Owner." }

# Auto-generate the body from live board data when not given
if (-not $Body) {
    $read  = Get-BoardItems -Number $ProjectNum -Owner $Owner `
                            -What "listar los items del board #$ProjectNum"
    $items = $read.Items
    $done    = @($items | Where-Object { $_.status -eq "Done" }).Count
    $inProg  = @($items | Where-Object { $_.status -eq "In Progress" }).Count
    $pending = @($items | Where-Object { (-not $_.status) -or ($_.status -eq "Backlog") })
    $total   = @($items).Count

    $next = ($pending | Sort-Object -Property @{Expression={ if ($_.priority) { $_.priority } else { "zz" } }} |
             Select-Object -First 3 | ForEach-Object {
                 if ($_.content.number) { "#$($_.content.number) $($_.title)" } else { $_.title }
             }) -join "; "

    $Body = "**Progreso:** $done Done / $inProg In Progress / $($pending.Count) Backlog ($total items)."
    if ($next) { $Body += "`n**Siguiente:** $next" }
    # Publish the caveat rather than a clean-looking lie: these counts are a floor when the read
    # hit its cap, and the reader of a status update has no way to know that otherwise (#484).
    if ($read.Truncated) {
        $Body += "`n_Nota: solo pude leer $($read.Read) items del board; las cuentas de arriba son un minimo, no un total._"
    }
}

$updQuery = '
mutation($p:ID!, $b:String!, $s:ProjectV2StatusUpdateStatus!) {
  createProjectV2StatusUpdate(input:{projectId:$p, body:$b, status:$s}) {
    statusUpdate { id createdAt }
  }
}'
$result = Invoke-Gh -GhArgs @('api','graphql','-f',"query=$updQuery",'-f',"p=$projectId",'-f',"b=$Body",'-f',"s=$Status") `
                    -What "publicar el status update" -Graphql

$id = $result.data.createProjectV2StatusUpdate.statusUpdate.id
if (-not $id) { throw "La mutacion no devolvio statusUpdate - revisa scopes del token." }

Write-Host "OK status update publicado ($Status):" -ForegroundColor Green
Write-Host $Body
Write-Host ""
Write-Host "Board: $boardUrl" -ForegroundColor Cyan
